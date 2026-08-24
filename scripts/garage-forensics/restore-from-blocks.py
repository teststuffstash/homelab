#!/usr/bin/env python3
"""Tier-2 restore: reassemble the Aug-4->24 delta from Garage's orphan blocks and re-PUT it.

Runs INSIDE the cluster (pod garage-forensics, data volume mounted read-only) so the 2.1 GB
never leaves the node. Stdlib only: SigV4 is ~40 lines and beats depending on pip in a pod.

Input : work.jsonl  {b,k,size,etag,ct,ts, d=<inline b64> | blocks=[hash,...]}
Safety: HEAD first — an existing key is NEVER overwritten (post-restore writes win).
Verify: md5(body) == stored etag for single-part objects; size always.
Output: report.jsonl, one line per object.
"""
import base64, hashlib, hmac, json, os, sys, threading, queue, urllib.request, urllib.error, urllib.parse, datetime

ENDPOINT = os.environ.get("S3_ENDPOINT", "http://garage-s3.garage.svc.cluster.local:3900")
REGION = os.environ.get("S3_REGION", "garage")
AK = os.environ["AWS_ACCESS_KEY_ID"]
SK = os.environ["AWS_SECRET_ACCESS_KEY"]
DATA = os.environ.get("GARAGE_DATA", "/mnt/data")
WORK = sys.argv[1]
REPORT = sys.argv[2]
THREADS = int(os.environ.get("THREADS", "4"))
DRY = os.environ.get("DRY_RUN") == "1"
LIMIT = int(os.environ.get("LIMIT", "0"))

try:
    from compression.zstd import decompress as zdec          # python 3.14+
except ImportError:  # pragma: no cover
    import zstandard
    zdec = lambda b: zstandard.ZstdDecompressor().decompressobj().decompress(b)


def sign(key, msg):
    return hmac.new(key, msg.encode(), hashlib.sha256).digest()


def sigv4(method, bucket, key, payload, headers):
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    host = urllib.parse.urlparse(ENDPOINT).netloc
    canon_uri = "/" + bucket + "/" + urllib.parse.quote(key, safe="/~-._")
    phash = hashlib.sha256(payload).hexdigest()
    hdrs = dict(headers)
    hdrs["host"] = host
    hdrs["x-amz-content-sha256"] = phash
    hdrs["x-amz-date"] = amzdate
    signed = ";".join(sorted(h.lower() for h in hdrs))
    canon_hdrs = "".join(f"{h}:{hdrs[h].strip()}\n" for h in sorted(hdrs, key=str.lower))
    canon_req = f"{method}\n{canon_uri}\n\n{canon_hdrs}\n{signed}\n{phash}"
    scope = f"{datestamp}/{REGION}/s3/aws4_request"
    to_sign = "AWS4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n" + hashlib.sha256(canon_req.encode()).hexdigest()
    k = sign(("AWS4" + SK).encode(), datestamp)
    k = sign(k, REGION)
    k = sign(k, "s3")
    k = sign(k, "aws4_request")
    sig = hmac.new(k, to_sign.encode(), hashlib.sha256).hexdigest()
    hdrs["Authorization"] = (f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, "
                             f"SignedHeaders={signed}, Signature={sig}")
    return ENDPOINT + canon_uri, hdrs


def s3(method, bucket, key, payload=b"", extra=None):
    url, hdrs = sigv4(method, bucket, key, payload, extra or {})
    req = urllib.request.Request(url, data=payload if method == "PUT" else None, method=method)
    for h, v in hdrs.items():
        req.add_header(h, v)
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            return r.status, dict(r.headers)
    except urllib.error.HTTPError as e:
        return e.code, {"body": e.read()[:300].decode("utf-8", "replace")}


def block_bytes(h):
    p = os.path.join(DATA, h[:2], h[2:4], h)
    if os.path.exists(p + ".zst"):
        with open(p + ".zst", "rb") as f:
            return zdec(f.read())
    if os.path.exists(p):
        with open(p, "rb") as f:
            return f.read()
    return None


def handle(rec):
    b, k = rec["b"], rec["k"]
    out = {"b": b, "k": k, "size": rec.get("size")}
    st, _ = s3("HEAD", b, k)
    if st == 200:
        out["r"] = "exists"
        return out
    if st not in (404, 403):
        out["r"] = f"head-{st}"
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
    st, info = s3("PUT", b, k, body, extra)
    out["r"] = "put-%d" % st
    if st != 200:
        out["err"] = str(info)[:200]
    return out


work = [json.loads(l) for l in open(WORK)]
if LIMIT:
    work = work[:LIMIT]
q = queue.Queue()
for r in work:
    q.put(r)
lock = threading.Lock()
fh = open(REPORT, "w")
done = [0]


def worker():
    while True:
        try:
            rec = q.get_nowait()
        except queue.Empty:
            return
        try:
            out = handle(rec)
        except Exception as e:                      # noqa: BLE001 - one bad object must not stop the run
            out = {"b": rec["b"], "k": rec["k"], "r": "exception", "err": repr(e)[:200]}
        with lock:
            fh.write(json.dumps(out) + "\n")
            done[0] += 1
            if done[0] % 250 == 0:
                fh.flush()
                print(f"{done[0]}/{len(work)}", flush=True)


ts = [threading.Thread(target=worker) for _ in range(THREADS)]
[t.start() for t in ts]
[t.join() for t in ts]
fh.close()
import collections
c = collections.Counter(json.loads(l)["r"] for l in open(REPORT))
print(json.dumps(dict(c), indent=2))
