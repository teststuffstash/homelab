#!/usr/bin/env python3
"""Tier-2 extraction: object + version records out of a raw Garage metadata layer.

Reads the raw Longhorn layer image (ext4 block == LMDB page == 4096, so every page
is one aligned block). Collects, for the target bucket ids:
  * bucket_alias entries   (key <32 zero bytes><name>) -> name -> bucket id
  * object-table entries   (marker G2s3ob) -> newest Complete version per key
  * version-table entries  (marker G09s3v) -> block list per version uuid
F_BIGDATA values live on overflow pages; the first overflow page carries its own
pgno in its header, and LMDB writes the value contiguously from that page's data
offset, so we index pgno -> image offset in the same pass and read it back.

Usage: lmdb-carve.py <layer.img> <outdir> [<bucket-id-hex> ...]
       with no bucket ids, every bucket named in the recovered alias table is carved.

Output: <out>/aliases.json, <out>/objects.jsonl, <out>/versions.jsonl, <out>/stats.json

Records are STREAMED through <out>/.raw-{objects,versions}.jsonl and only the winning
line of each key is copied out, so a whole-store carve (~1M objects) stays inside a
few hundred MB of RAM. Holding the decoded records was what a 3-bucket carve could
afford and a 13-bucket one could not.
"""
import struct, sys, json, base64, os, collections
import msgpack

PG, P_LEAF, F_BIGDATA = 4096, 2, 0x01
OBJ_MARK, VER_MARK = b"G2s3ob", b"G09s3v"
ZERO32 = b"\x00" * 32

PATH = sys.argv[1]
OUT = sys.argv[2]
TARGETS = {bytes.fromhex(h) for h in sys.argv[3:]}
os.makedirs(OUT, exist_ok=True)

pg_off = {}                 # pgno -> image offset (for overflow resolution)
big_refs = []               # (kind, key, pgno, dsize)
aliases = {}                # name -> (ts, bucket id hex)
obj_pick = {}               # (bucket idx, key) -> (ts, seq)     -- the winning line
ver_pick = {}               # version uuid      -> (vallen, seq) -- the longest line
bidx = {}                   # bucket id bytes -> small int (keeps obj_pick keys cheap)
stats = collections.Counter()

RAW_OBJ = os.path.join(OUT, ".raw-objects.jsonl")
RAW_VER = os.path.join(OUT, ".raw-versions.jsonl")


class Spool:
    """Append-only JSONL spool that hands back each line's byte offset (text-mode
    tell() returns an opaque cookie, and pass 3 seeks with a separate handle)."""

    def __init__(self, path):
        self.fh = open(path, "wb")
        self.pos = 0

    def write(self, rec):
        off = self.pos
        b = (json.dumps(rec) + "\n").encode()
        self.fh.write(b)
        self.pos += len(b)
        return off

    def close(self):
        self.fh.close()


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


def emit_object(key, val, fh):
    """Decode one object row and stream every Complete version of it; index the newest."""
    try:
        o = unpack(val, OBJ_MARK)
    except Exception:
        stats["obj_decode_fail"] += 1
        return
    bid_b = key[:32]
    bid = bid_b.hex()
    bi = bidx.setdefault(bid_b, len(bidx))
    okey = o.get("key")
    newest = None
    for v in o.get("versions", []):
        st, ts, uuid = v.get("state"), v.get("timestamp"), v.get("uuid")
        rec = {"bucket": bid, "key": okey,
               "uuid": uuid.hex() if isinstance(uuid, (bytes, bytearray)) else None, "ts": ts}
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
        if newest is None or (rec["ts"] or 0) > (newest["ts"] or 0):
            newest = rec
    if newest is None:
        stats["obj_no_versions"] += 1
        return
    ident = (bi, okey)
    cur = obj_pick.get(ident)
    if cur is not None and cur[0] >= (newest["ts"] or 0):
        return
    obj_pick[ident] = ((newest["ts"] or 0), fh.write(newest))


def emit_version(uid, val, fh):
    try:
        v = unpack(val, VER_MARK)
    except Exception:
        stats["ver_decode_fail"] += 1
        return
    blocks = []
    b = v.get("blocks", {})
    for pair in (b.get("vals", []) if isinstance(b, dict) else []):
        try:
            bk, bv = pair
            blocks.append({"part": bk.get("part_number"), "offset": bk.get("offset"),
                           "hash": bytes(bv["hash"]).hex(), "size": bv["size"]})
        except Exception:
            stats["ver_block_fail"] += 1
    bl = v.get("backlink", {})
    obj = bl.get("Object", {}) if isinstance(bl, dict) else {}
    # a version row grows as blocks land; the longest survivor is the latest
    cur = ver_pick.get(uid)
    if cur is not None and cur[0] >= len(val):
        return
    ver_pick[uid] = (len(val), fh.write(
        {"uuid": uid.hex(), "deleted": v.get("deleted"), "blocks": blocks,
         "bucket": bytes(obj["bucket_id"]).hex() if obj.get("bucket_id") else None,
         "key": obj.get("key")}))


# ---- pass 1: scan every page, stream what it holds ---------------------------
fobj, fver = Spool(RAW_OBJ), Spool(RAW_VER)
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
            is_obj = ksize > 32 and (not TARGETS or key[:32] in TARGETS)
            is_ver = ksize == 32
            is_alias = ksize > 32 and key[:32] == ZERO32
            if not (is_obj or is_ver or is_alias):
                continue
            if nflags & F_BIGDATA:
                if vs + 8 > PG or is_alias:
                    continue
                opg = struct.unpack_from("<Q", buf, vs)[0]
                big_refs.append(("obj" if is_obj else "ver", key, opg, dsize))
                stats["bigdata_ref"] += 1
                continue
            if vs + dsize > PG:
                continue
            val = buf[vs:vs + dsize]
            if is_alias:
                # bucket_alias: key = <32 zero bytes><global alias>, value = {name, state:{ts,v}}
                try:
                    d = msgpack.unpackb(val, raw=False, strict_map_key=False)
                    st = d["state"]
                    ts, v = st.get("ts"), st.get("v")
                except Exception:
                    continue
                name = key[32:].decode("utf-8", "replace")
                if v is not None and (name not in aliases or (ts or 0) > aliases[name][0]):
                    aliases[name] = (ts or 0, bytes(v).hex())
                    stats["alias_row"] += 1
                continue
            if is_obj and val[:6] == OBJ_MARK:
                emit_object(key, val, fobj)
                stats["obj_inline_page"] += 1
            elif is_ver and val[:6] == VER_MARK:
                emit_version(key, val, fver)
                stats["ver_page"] += 1

# ---- pass 2: resolve overflow object values ----------------------------------
with open(PATH, "rb") as f:
    for kind, key, opg, dsize in big_refs:
        o = pg_off.get(opg)
        if o is None:
            stats["bigdata_missing_page"] += 1
            continue
        f.seek(o + 16)
        val = f.read(dsize)
        if kind == "obj" and val[:6] == OBJ_MARK:
            emit_object(key, val, fobj)
            stats["obj_overflow"] += 1
        elif kind == "ver" and val[:6] == VER_MARK:
            emit_version(key, val, fver)
            stats["ver_overflow"] += 1
        else:
            stats["bigdata_bad_marker"] += 1
fobj.close()
fver.close()

# ---- pass 3: copy out the winning line of each key ---------------------------
if not TARGETS:
    TARGETS = {bytes.fromhex(v[1]) for v in aliases.values()}
keep_bid = {i for b, i in bidx.items() if b in TARGETS}


def sift(raw, picks, out_name, wanted=None):
    n = 0
    with open(raw, "rb") as src, open(os.path.join(OUT, out_name), "w") as dst:
        for ident, (_, seq) in picks.items():
            if wanted is not None and ident[0] not in wanted:
                continue
            src.seek(seq)
            dst.write(src.readline().decode())
            n += 1
    os.unlink(raw)
    return n


stats["objects_distinct"] = sift(RAW_OBJ, obj_pick, "objects.jsonl", keep_bid)
stats["versions_written"] = sift(RAW_VER, ver_pick, "versions.jsonl")
stats["buckets_named"] = len(aliases)

with open(os.path.join(OUT, "aliases.json"), "w") as fh:
    json.dump({n: b for n, (_, b) in sorted(aliases.items())}, fh, indent=2)
with open(os.path.join(OUT, "stats.json"), "w") as fh:
    json.dump(dict(stats), fh, indent=2)
print(json.dumps(dict(stats), indent=2))
