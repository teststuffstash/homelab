#!/usr/bin/env python3
"""Tier-2 extraction: object + version records for the target buckets.

Reads the raw Longhorn layer image (ext4 block == LMDB page == 4096, so every page
is one aligned block). Collects, for the target bucket ids:
  * object-table entries  (marker G2s3ob) -> newest Complete version per key
  * version-table entries (marker G09s3v) -> block list per version uuid
F_BIGDATA values live on overflow pages; the first overflow page carries its own
pgno in its header, and LMDB writes the value contiguously from that page's data
offset, so we index pgno -> image offset in the same pass and read it back.

Output: <out>/objects.jsonl, <out>/versions.jsonl, <out>/stats.json
"""
import struct, sys, json, base64, os, collections
import msgpack

PG, P_LEAF, F_BIGDATA = 4096, 2, 0x01
OBJ_MARK, VER_MARK = b"G2s3ob", b"G09s3v"

PATH = sys.argv[1]
OUT = sys.argv[2]
TARGETS = {bytes.fromhex(h) for h in sys.argv[3:]}
os.makedirs(OUT, exist_ok=True)

pg_off = {}                 # pgno -> image offset (for overflow resolution)
big_refs = []               # (kind, key, pgno, dsize)
obj_raw = []                # (key, value bytes)
ver_raw = {}                # uuid bytes -> value bytes (last wins; dedup below)
stats = collections.Counter()

with open(PATH, "rb") as f:
    base = 0
    while True:
        buf = f.read(PG)
        if not buf or len(buf) < PG:
            break
        off_img, base = base, base + PG
        if buf == b"\x00" * PG:
            continue
        pgno, pad, flags, lower, upper = struct.unpack_from("<QHHHH", buf, 0)
        pg_off[pgno] = off_img
        if flags != P_LEAF or not (16 <= lower <= upper <= PG):
            continue
        n = (lower - 16) // 2
        if n > 400:
            continue
        for i in range(n):
            off = struct.unpack_from("<H", buf, 16 + 2 * i)[0]
            if off < 16 or off > PG - 8:
                continue
            lo, hi, nflags, ksize = struct.unpack_from("<HHHH", buf, off)
            dsize = lo | (hi << 16)
            if ksize == 0 or off + 8 + ksize > PG:
                continue
            key = buf[off + 8: off + 8 + ksize]
            vs = off + 8 + ksize
            is_obj = ksize > 32 and key[:32] in TARGETS
            is_ver = ksize == 32
            if not (is_obj or is_ver):
                continue
            if nflags & F_BIGDATA:
                if vs + 8 > PG:
                    continue
                opg = struct.unpack_from("<Q", buf, vs)[0]
                big_refs.append(("obj" if is_obj else "ver", key, opg, dsize))
                stats["bigdata_ref"] += 1
                continue
            if vs + dsize > PG:
                continue
            val = buf[vs:vs + dsize]
            if is_obj and val[:6] == OBJ_MARK:
                obj_raw.append((key, val))
                stats["obj_inline_page"] += 1
            elif is_ver and val[:6] == VER_MARK:
                # a version row grows as blocks land; the longest survivor is the latest
                if len(val) > len(ver_raw.get(key, b"")):
                    ver_raw[key] = val
                stats["ver_page"] += 1

# ---- resolve overflow values -------------------------------------------------
with open(PATH, "rb") as f:
    for kind, key, opg, dsize in big_refs:
        o = pg_off.get(opg)
        if o is None:
            stats["bigdata_missing_page"] += 1
            continue
        f.seek(o + 16)
        val = f.read(dsize)
        if kind == "obj" and val[:6] == OBJ_MARK:
            obj_raw.append((key, val))
            stats["obj_overflow"] += 1
        elif kind == "ver" and val[:6] == VER_MARK:
            ver_raw[key] = val
            stats["ver_overflow"] += 1
        else:
            stats["bigdata_bad_marker"] += 1

# ---- decode ------------------------------------------------------------------
def unpack(val, mark):
    return msgpack.unpackb(val[len(mark):], raw=False, strict_map_key=False)


def headers_of(meta):
    """meta.encryption.Plaintext.inner.headers -> [[name, value], ...] (garage v2 shape)."""
    try:
        enc = meta.get("encryption") or {}
        inner = (enc.get("Plaintext") or {}).get("inner") or {}
        return inner.get("headers") or []
    except AttributeError:
        return []

best = {}       # (bid, key) -> record
for key, val in obj_raw:
    try:
        o = unpack(val, OBJ_MARK)
    except Exception:
        stats["obj_decode_fail"] += 1
        continue
    bid = key[:32].hex()
    okey = o.get("key")
    for v in o.get("versions", []):
        st = v.get("state")
        ts = v.get("timestamp")
        uuid = v.get("uuid")
        rec = {"bucket": bid, "key": okey, "uuid": uuid.hex() if isinstance(uuid, (bytes, bytearray)) else None,
               "ts": ts}
        if isinstance(st, dict) and "Complete" in st:
            c = st["Complete"]
            if isinstance(c, dict) and "Inline" in c:
                meta, data = c["Inline"]
                rec.update(kind="inline", size=meta.get("size"), etag=meta.get("etag"),
                           headers=headers_of(meta), data_b64=base64.b64encode(bytes(data)).decode())
            elif isinstance(c, dict) and "FirstBlock" in c:
                meta, h = c["FirstBlock"]
                rec.update(kind="firstblock", size=meta.get("size"), etag=meta.get("etag"),
                           headers=headers_of(meta), first_block=bytes(h).hex())
            else:
                rec.update(kind="complete-other", raw=str(c)[:200])
        elif isinstance(st, str) and st == "Aborted":
            rec.update(kind="aborted")
        else:
            rec.update(kind="incomplete", raw=str(st)[:120])
        cur = best.get((bid, okey))
        if cur is None or (rec["ts"] or 0) > (cur["ts"] or 0):
            best[(bid, okey)] = rec

with open(os.path.join(OUT, "objects.jsonl"), "w") as fh:
    for rec in best.values():
        fh.write(json.dumps(rec) + "\n")

nver = 0
with open(os.path.join(OUT, "versions.jsonl"), "w") as fh:
    for uid, val in ver_raw.items():
        try:
            v = unpack(val, VER_MARK)
        except Exception:
            stats["ver_decode_fail"] += 1
            continue
        blocks = []
        b = v.get("blocks", {})
        vals = b.get("vals", []) if isinstance(b, dict) else []
        for pair in vals:
            try:
                bk, bv = pair
                blocks.append({"part": bk.get("part_number"), "offset": bk.get("offset"),
                               "hash": bytes(bv["hash"]).hex(), "size": bv["size"]})
            except Exception:
                stats["ver_block_fail"] += 1
        bl = v.get("backlink", {})
        obj = bl.get("Object", {}) if isinstance(bl, dict) else {}
        fh.write(json.dumps({"uuid": uid.hex(), "deleted": v.get("deleted"), "blocks": blocks,
                             "bucket": bytes(obj["bucket_id"]).hex() if obj.get("bucket_id") else None,
                             "key": obj.get("key")}) + "\n")
        nver += 1

stats["objects_distinct"] = len(best)
stats["versions_written"] = nver
with open(os.path.join(OUT, "stats.json"), "w") as fh:
    json.dump(dict(stats), fh, indent=2)
print(json.dumps(dict(stats), indent=2))
