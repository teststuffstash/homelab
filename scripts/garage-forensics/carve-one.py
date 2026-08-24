#!/usr/bin/env python3
"""Carve ONE object out of the orphan blocks to a local file (no S3 write)."""
import base64, hashlib, json, os, sys
try:
    from compression.zstd import decompress as zdec
except ImportError:
    import zstandard
    zdec = lambda b: zstandard.ZstdDecompressor().decompressobj().decompress(b)
WORK, BUCKET, KEY, OUT = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
DATA = os.environ.get("GARAGE_DATA", "/mnt/data")
for line in open(WORK):
    r = json.loads(line)
    if r["b"] != BUCKET or r["k"] != KEY:
        continue
    if "d" in r:
        body = base64.b64decode(r["d"])
    else:
        body = b""
        for h in r["blocks"]:
            p = os.path.join(DATA, h[:2], h[2:4], h)
            if os.path.exists(p + ".zst"):
                body += zdec(open(p + ".zst", "rb").read())
            elif os.path.exists(p):
                body += open(p, "rb").read()
            else:
                sys.exit("block missing: " + h)
    md5 = hashlib.md5(body).hexdigest()
    open(OUT, "wb").write(body)
    print(json.dumps({"key": KEY, "size": len(body), "expect_size": r["size"],
                      "md5": md5, "etag": r["etag"], "ok": md5 == r["etag"] and len(body) == r["size"],
                      "ts": r["ts"]}))
    break
else:
    sys.exit("not found in work file")
