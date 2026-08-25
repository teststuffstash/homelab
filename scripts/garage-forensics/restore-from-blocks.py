#!/usr/bin/env python3
"""Tier-2 restore: reassemble the Aug-4->24 delta from Garage's orphan blocks and re-PUT it.

Runs INSIDE the cluster (pod garage-forensics, data volume mounted read-only) so the 2.1 GB
never leaves the node. Stdlib only: SigV4 is ~40 lines and beats depending on pip in a pod.

Input : work.jsonl  {b,k,size,etag,ct,ts, d=<inline b64> | blocks=[hash,...]}
Safety: HEAD first — an existing key is NEVER overwritten (post-restore writes win).
Verify: md5(body) == stored etag for single-part objects; size always.
Output: report.jsonl, one line per object.

PRESCAN=1 answers "is the data even still on disk?" without reading or writing any of it:
it only stats each object's block files. Worth a pass before a large run — a carve can name
far more bytes than survive, and the blocks of anything deleted before the wipe are gone
(that delete dropped their refcount, so Garage's GC took them on its own timer).
"""
import base64, collections, hashlib, hmac, json, os, re, sys, threading, queue, urllib.request, urllib.error, urllib.parse, datetime

ENDPOINT = os.environ.get("S3_ENDPOINT", "http://garage-s3.garage.svc.cluster.local:3900")
REGION = os.environ.get("S3_REGION", "garage")
DATA = os.environ.get("GARAGE_DATA", "/mnt/data")
WORK = sys.argv[1]
REPORT = sys.argv[2]
THREADS = int(os.environ.get("THREADS", "4"))
DRY = os.environ.get("DRY_RUN") == "1"
PRESCAN = os.environ.get("PRESCAN") == "1"     # stat blocks only; talks to no endpoint
LIMIT = int(os.environ.get("LIMIT", "0"))
MAX_BODY = int(os.environ.get("MAX_BODY", str(512 << 20)))     # in-memory reassembly ceiling
PROGRESS = os.environ.get("PROGRESS") == "1"   # per-part lines for the few very large objects
AK = os.environ.get("AWS_ACCESS_KEY_ID", "")
SK = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
if not PRESCAN and not (AK and SK):
    sys.exit("AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY required (unless PRESCAN=1)")

try:
    from compression.zstd import decompress as zdec          # python 3.14+
except ImportError:  # pragma: no cover
    import zstandard
    zdec = lambda b: zstandard.ZstdDecompressor().decompressobj().decompress(b)


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def sigv4(method, bucket, key, payload, headers, query=None):
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    host = urllib.parse.urlparse(ENDPOINT).netloc
    canon_uri = "/" + bucket + "/" + urllib.parse.quote(key, safe="/~-._")
    canon_qs = "&".join(f"{urllib.parse.quote(q, safe='')}={urllib.parse.quote(v, safe='')}"
                        for q, v in sorted((query or {}).items()))
    phash = hashlib.sha256(payload).hexdigest()
    hdrs = dict(headers)
    hdrs["host"] = host
    hdrs["x-amz-content-sha256"] = phash
    hdrs["x-amz-date"] = amzdate
    signed = ";".join(sorted(h.lower() for h in hdrs))
    canon_hdrs = "".join(f"{h}:{hdrs[h].strip()}\n" for h in sorted(hdrs, key=str.lower))
    canon_req = f"{method}\n{canon_uri}\n{canon_qs}\n{canon_hdrs}\n{signed}\n{phash}"
    scope = f"{datestamp}/{REGION}/s3/aws4_request"
    to_sign = "AWS4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n" + hashlib.sha256(canon_req.encode()).hexdigest()
    k = sign(("AWS4" + SK).encode(), datestamp)
    k = sign(k, REGION)
    k = sign(k, "s3")
    k = sign(k, "aws4_request")
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    hdrs["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
                             f"SignedHeaders={signed}, Signature={sig}")
    return ENDPOINT + canon_uri + (("?" + canon_qs) if canon_qs else ""), hdrs


def s3(method, bucket, key, payload=b"", extra=None, query=None):
    """-> (status, headers, body). Body matters for the multipart handshake."""
    url, hdrs = sigv4(method, bucket, key, payload, extra or {}, query)
    req = urllib.request.Request(url, data=payload if method in ("PUT", "POST") else None,
                                 method=method)
    for h, v in hdrs.items():
        req.add_header(h, v)
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            return r.status, dict(r.headers), (b"" if method == "HEAD" else r.read())
    except urllib.error.HTTPError as e:
        return e.code, {}, e.read()[:600]


def block_path(h):
    p = os.path.join(DATA, h[:2], h[2:4], h)
    if os.path.exists(p + ".zst"):
        return p + ".zst", True
    if os.path.exists(p):
        return p, False
    return None, False


def block_bytes(h):
    p, compressed = block_path(h)
    if p is None:
        return None
    with open(p, "rb") as f:
        raw = f.read()
    return zdec(raw) if compressed else raw


def prescan(rec):
    """Stat-only: does every block this object needs still exist?"""
    out = {"b": rec["b"], "k": rec["k"], "size": rec.get("size")}
    if "d" in rec:
        out["r"] = "inline"
        return out
    missing = [h for h in rec["blocks"] if block_path(h)[0] is None]
    if missing:
        out["r"] = "block-missing"
        out["n_missing"] = len(missing)
        out["block"] = missing[0]
    else:
        out["r"] = "blocks-present"
    return out


def put_multipart(rec, out):
    """Re-upload a multipart object part-by-part, so only one part is ever in memory.

    The carve keeps each block's part_number, which is what makes this exact: replaying the
    original part boundaries reproduces the stored `<md5-of-part-md5s>-<n>` ETag, and a
    mismatch aborts the upload instead of completing a wrong object.
    """
    b, k = rec["b"], rec["k"]
    groups = collections.OrderedDict()
    for h, p in zip(rec["blocks"], rec["bparts"]):
        groups.setdefault(p, []).append(h)
    extra = {"content-type": rec["ct"]} if rec.get("ct") else {}
    upload_id = None
    if not DRY:
        st, _, body = s3("POST", b, k, b"", extra, {"uploads": ""})
        if st != 200:
            out["r"] = "mpu-create-%d" % st
            out["err"] = body[:200].decode("utf-8", "replace")
            return out
        m = re.search(rb"<UploadId>([^<]+)</UploadId>", body)
        if not m:
            out["r"] = "mpu-no-upload-id"
            return out
        upload_id = m.group(1).decode()
    digests, done, total = [], 0, 0
    try:
        for n, hashes in enumerate(groups.values(), start=1):
            part = []
            for h in hashes:
                bb = block_bytes(h)
                if bb is None:
                    out["r"] = "block-missing"
                    out["block"] = h
                    return out
                part.append(bb)
            part = b"".join(part)
            digests.append(hashlib.md5(part).digest())
            total += len(part)
            if not DRY:
                st, _, body = s3("PUT", b, k, part, {},
                                 {"partNumber": str(n), "uploadId": upload_id})
                if st != 200:
                    out["r"] = "mpu-part-%d" % st
                    out["part"] = n
                    out["err"] = body[:200].decode("utf-8", "replace")
                    return out
            done = n
            if PROGRESS:
                print(f"    {k[-40:]} part {n}/{len(groups)} ({total / 1e9:.1f} GB)", flush=True)
        etag = hashlib.md5(b"".join(digests)).hexdigest() + "-" + str(len(digests))
        out["computed_etag"] = etag
        out["got"] = total
        if rec.get("size") is not None and total != rec["size"]:
            out["r"] = "size-mismatch"
            return out
        if rec.get("etag") and etag != rec["etag"]:
            out["r"] = "etag-mismatch"
            return out
        parts_xml = "".join(f"<Part><PartNumber>{i}</PartNumber>"
                            f"<ETag>&#34;{d.hex()}&#34;</ETag></Part>"
                            for i, d in enumerate(digests, start=1))
        xml = ("<CompleteMultipartUpload>" + parts_xml + "</CompleteMultipartUpload>").encode()
        if DRY:
            out["r"] = "dry-ok"
            out["v"] = "multipart-etag-ok"
            return out
        st, _, body = s3("POST", b, k, xml, {}, {"uploadId": upload_id})
        out["r"] = "put-%d" % st
        out["v"] = "multipart-etag-ok"
        if st != 200:
            out["err"] = body[:200].decode("utf-8", "replace")
        else:
            upload_id = None
        return out
    finally:
        if upload_id:
            # never leave a half-finished upload holding block refs
            s3("DELETE", b, k, b"", {}, {"uploadId": upload_id})
            out["aborted_after_parts"] = done


def handle(rec):
    if PRESCAN:
        return prescan(rec)
    b, k = rec["b"], rec["k"]
    out = {"b": b, "k": k, "size": rec.get("size")}
    st, _, _ = s3("HEAD", b, k)
    if st == 200:
        out["r"] = "exists"
        return out
    if st not in (404, 403):
        out["r"] = f"head-{st}"
        return out
    if (rec.get("size") or 0) > MAX_BODY:
        # too big to reassemble in memory: multipart replays it a part at a time, and
        # anything else is out of this tool's reach
        if rec.get("bparts"):
            return put_multipart(rec, out)
        out["r"] = "too-large"
        return out
    if "d" in rec:
        body = base64.b64decode(rec["d"])
    else:
        parts = []
        for h in rec["blocks"]:
            bb = block_bytes(h)
            if bb is None:
                out["r"] = "block-missing"
                out["block"] = h
                return out
            parts.append(bb)
        body = b"".join(parts)
    if rec.get("size") is not None and len(body) != rec["size"]:
        out["r"] = "size-mismatch"
        out["got"] = len(body)
        return out
    etag = rec.get("etag") or ""
    if "-" not in etag:
        if hashlib.md5(body).hexdigest() != etag:
            out["r"] = "etag-mismatch"
            return out
        out["v"] = "etag-ok"
    else:
        out["v"] = "multipart-etag-unchecked"
    if DRY:
        out["r"] = "dry-ok"
        return out
    extra = {"content-type": rec["ct"]} if rec.get("ct") else {}
    st, _, info = s3("PUT", b, k, body, extra)
    out["r"] = "put-%d" % st
    if st != 200:
        out["err"] = info[:200].decode("utf-8", "replace")
    return out


total = sum(1 for _ in open(WORK))
if LIMIT:
    total = min(total, LIMIT)
# STREAM the manifest — a whole-store carve is a ~0.5 GB work file whose parsed form does
# not fit the pod's memory limit, and the queue is bounded for the same reason.
q = queue.Queue(maxsize=4096)
lock = threading.Lock()
fh = open(REPORT, "w")
done = [0]


def feeder():
    n = 0
    with open(WORK) as src:
        for line in src:
            if LIMIT and n >= LIMIT:
                break
            q.put(json.loads(line))
            n += 1
    for _ in range(THREADS):
        q.put(None)


def worker():
    while True:
        rec = q.get()
        if rec is None:
            return
        try:
            out = handle(rec)
        except Exception as e:                      # noqa: BLE001 - one bad object must not stop the run
            out = {"b": rec["b"], "k": rec["k"], "r": "exception", "err": repr(e)[:200]}
        with lock:
            fh.write(json.dumps(out) + "\n")
            fh.flush()          # a killed run must not lose the report of what it already did
            done[0] += 1
            if done[0] % 250 == 0:
                print(f"{done[0]}/{total}", flush=True)


fd = threading.Thread(target=feeder, daemon=True)
fd.start()
ts = [threading.Thread(target=worker) for _ in range(THREADS)]
[t.start() for t in ts]
[t.join() for t in ts]
fd.join()
fh.close()
c = collections.Counter(json.loads(l)["r"] for l in open(REPORT))
print(json.dumps(dict(c), indent=2))
