#!/usr/bin/env python3
"""Join a carve into the restore's work list: objects.jsonl + versions.jsonl -> work.jsonl.

Turns carved table records into the manifest `restore-from-blocks.py` / `verify-restored.py`
consume, resolving bucket ids to the names S3 addresses buckets by (from the carve's
recovered alias table) and dropping anything that was not a Complete version.

Usage: build-work.py <carve-dir> <work.jsonl> [--only a,b] [--exclude a,b]
                     [--live <dir-of-'<bucket>.keys'>] [--since <epoch-ms>]

  --only / --exclude  bucket NAMES (an unaliased bucket id also works)
  --live              directory of `<bucket>.keys` files (one live object key per line,
                      e.g. from `garage-s3 s3 ls --recursive`); keys already present are
                      skipped, so the run is the delta and not a million no-op HEADs.
                      The restore never overwrites either — this is the cheap half.
  --since             keep only objects newer than an epoch-ms timestamp

Prints a per-bucket summary of what went in and what was dropped, and why.
"""
import json, os, sys, collections

CARVE, OUT = sys.argv[1], sys.argv[2]
argv = sys.argv[3:]


def opt(flag, default=None):
    return argv[argv.index(flag) + 1] if flag in argv else default


ONLY = set(filter(None, (opt("--only", "") or "").split(",")))
EXCLUDE = set(filter(None, (opt("--exclude", "") or "").split(",")))
LIVE = opt("--live")
SINCE = int(opt("--since", "0"))

aliases = json.load(open(os.path.join(CARVE, "aliases.json")))
name_of = {bid: n for n, bid in aliases.items()}

blocks_of = {}
for line in open(os.path.join(CARVE, "versions.jsonl")):
    v = json.loads(line)
    if v["blocks"]:
        # LMDB orders the block map by (part_number, offset); sort anyway — a truncated
        # or re-read row must not silently reassemble an object out of order.
        bl = sorted(v["blocks"], key=lambda b: ((b.get("part") or 0), (b.get("offset") or 0)))
        blocks_of[v["uuid"]] = ([b["hash"] for b in bl], [b["size"] for b in bl],
                                [b.get("part") or 1 for b in bl])

live = {}
if LIVE:
    for fn in os.listdir(LIVE):
        if fn.endswith(".keys"):
            with open(os.path.join(LIVE, fn)) as fh:
                live[fn[:-5]] = {l.rstrip("\n") for l in fh if l.strip()}

drop = collections.Counter()
kept = collections.Counter()
kept_bytes = collections.Counter()
with open(OUT, "w") as out:
    for line in open(os.path.join(CARVE, "objects.jsonl")):
        r = json.loads(line)
        b = name_of.get(r["bucket"], r["bucket"])
        if (ONLY and b not in ONLY) or b in EXCLUDE:
            drop[(b, "out-of-scope")] += 1
            continue
        if r["kind"] not in ("inline", "firstblock"):
            drop[(b, "not-complete:" + r["kind"])] += 1
            continue
        if SINCE and (r.get("ts") or 0) < SINCE:
            drop[(b, "older-than-since")] += 1
            continue
        if r["key"] in live.get(b, ()):
            drop[(b, "already-live")] += 1
            continue
        ct = next((v for k, v in (r.get("headers") or []) if k.lower() == "content-type"), None)
        rec = {"b": b, "k": r["key"], "size": r.get("size"), "etag": r.get("etag"),
               "ct": ct, "ts": r.get("ts")}
        if r["kind"] == "inline":
            rec["d"] = r["data_b64"]
        else:
            bl = blocks_of.get(r["uuid"])
            if bl is None:
                drop[(b, "no-version-row")] += 1
                continue
            rec["blocks"], rec["bsizes"], parts = bl
            if len(set(parts)) > 1:
                # multipart: the part boundaries are what reproduces the stored "<md5>-<n>"
                # ETag, so they have to survive into the manifest
                rec["bparts"] = parts
        out.write(json.dumps(rec) + "\n")
        kept[b] += 1
        kept_bytes[b] += r.get("size") or 0

print("kept:")
for b in sorted(kept):
    print(f"  {b:32s} {kept[b]:>8d}  {kept_bytes[b] / 1e9:8.2f} GB")
print(f"  {'TOTAL':32s} {sum(kept.values()):>8d}  {sum(kept_bytes.values()) / 1e9:8.2f} GB")
print("dropped:")
for (b, why), n in sorted(drop.items()):
    print(f"  {b:32s} {why:24s} {n:>8d}")
