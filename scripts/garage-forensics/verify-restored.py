#!/usr/bin/env python3
"""Independent end-state check: HEAD every recovered key over the LAN S3 endpoint and
compare ContentLength + ETag against the carved metadata manifest (work.jsonl).

Deliberately a DIFFERENT path from the restore (jail -> https://s3.teststuff.net, not
in-pod -> cluster Service), so a shared-fate bug in the writer cannot hide a bad object.
"""
import concurrent.futures as cf
import collections, datetime, hashlib, hmac, json, os, ssl, sys, urllib.error, urllib.parse, urllib.request

ENDPOINT = os.environ.get("S3_ENDPOINT", "https://s3.teststuff.net")
REGION = os.environ.get("S3_REGION", "garage")
AK, SK = os.environ["AWS_ACCESS_KEY_ID"], os.environ["AWS_SECRET_ACCESS_KEY"]
WORK, REPORT = sys.argv[1], sys.argv[2]
CTX = ssl.create_default_context()


def sign(k, m):
    return hmac.new(k, m.encode(), hashlib.sha256).digest()


def head(bucket, key):
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate, datestamp = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    host = urllib.parse.urlparse(ENDPOINT).netloc
    uri = "/" + bucket + "/" + urllib.parse.quote(key, safe="/~-._")
    phash = hashlib.sha256(b"").hexdigest()
    hdrs = {"host": host, "x-amz-content-sha256": phash, "x-amz-date": amzdate}
    signed = ";".join(sorted(hdrs))
    canon = "".join(f"{h}:{hdrs[h]}\n" for h in sorted(hdrs))
    creq = f"HEAD\n{uri}\n\n{canon}\n{signed}\n{phash}"
    scope = f"{datestamp}/{REGION}/s3/aws4_request"
    tos = "AWS4-HMAC-SHA256\n" + amzdate + "\n" + scope + "\n" + hashlib.sha256(creq.encode()).hexdigest()
    k = sign(("AWS4" + SK).encode(), datestamp)
    for p in (REGION, "s3", "aws4_request"):
        k = sign(k, p)
    sig = hmac.new(k, tos.encode(), hashlib.sha256).hexdigest()
    hdrs["Authorization"] = f"AWS4-HMAC-SHA256 Credential={AK}/{scope}, SignedHeaders={signed}, Signature={sig}"
    req = urllib.request.Request(ENDPOINT + uri, method="HEAD")
    for h, v in hdrs.items():
        req.add_header(h, v)
    try:
        with urllib.request.urlopen(req, timeout=60, context=CTX) as r:
            # HTTPMessage is case-insensitive; dict() would lose that (Garage sends lowercase)
            return r.status, r.headers
    except urllib.error.HTTPError as e:
        return e.code, None


def check(rec):
    st, h = head(rec["b"], rec["k"])
    if st != 200:
        return {"k": rec["k"], "b": rec["b"], "r": f"head-{st}"}
    size = int(h.get("Content-Length") or -1)
    etag = (h.get("ETag") or "").strip('"')
    if size != rec["size"]:
        return {"k": rec["k"], "b": rec["b"], "r": "size-mismatch", "live": size, "want": rec["size"]}
    if "-" not in (rec.get("etag") or "") and etag != rec["etag"]:
        return {"k": rec["k"], "b": rec["b"], "r": "etag-mismatch", "live": etag, "want": rec["etag"]}
    return {"k": rec["k"], "b": rec["b"], "r": "ok"}


WORKERS = int(os.environ.get("THREADS", "16"))
res = collections.Counter()


def records():
    """Streamed — a whole-store manifest carries inline payloads and does not fit in RAM."""
    with open(WORK) as src:
        for line in src:
            r = json.loads(line)
            yield {"b": r["b"], "k": r["k"], "size": r["size"], "etag": r.get("etag")}


with open(REPORT, "w") as fh, cf.ThreadPoolExecutor(max_workers=WORKERS) as ex:
    def collect(fut):
        out = fut.result()
        res[out["r"]] += 1
        if out["r"] != "ok":
            fh.write(json.dumps(out) + "\n")
        if sum(res.values()) % 5000 == 0:
            print(sum(res.values()), dict(res), flush=True)

    pending = set()
    for rec in records():
        pending.add(ex.submit(check, rec))
        if len(pending) >= WORKERS * 16:
            ready, pending = cf.wait(pending, return_when=cf.FIRST_COMPLETED)
            for fut in ready:
                collect(fut)
    for fut in cf.as_completed(pending):
        collect(fut)
print(json.dumps(dict(res), indent=2))
