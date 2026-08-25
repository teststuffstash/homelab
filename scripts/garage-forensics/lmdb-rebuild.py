#!/usr/bin/env python3
"""Rebuild Garage's metadata LMDB env by insertion, dropping leaked pages.

Why insertion and not a copy: LMDB's own compacting copy (MDB_CP_COMPACT — what
`metadata_auto_snapshot_interval` uses) refuses any env with leaked pages. It predicts the
compacted root as `next_pgno - 1 - freecount` and returns MDB_INCOMPATIBLE when the walk
disagrees (mdb.c: "page leak or corrupt DB"). Garage's own `convert-db` cannot do it either:
it rejects lmdb->lmdb ("input and output database engine must differ"), and on a damaged env
it dies earlier still, in list_trees(), on a main-DB key that is not valid UTF-8.

So: read every named tree through a read-only txn and re-insert in key order (append mode,
which packs leaves densely), then take a compacting copy of the result — which now succeeds,
and is itself the proof that the auto-snapshot belt will work on the rebuilt env.

Usage:  lmdb-rebuild.py <src data.mdb> <out data.mdb> [--map-size-gib N]
Exits non-zero unless every tree's entry count matches the source exactly.
"""
import json, os, sys, time
import lmdb

BATCH = 20000


def open_src(path, map_gib):
    return lmdb.open(path, subdir=False, readonly=True, lock=False,
                     max_dbs=256, map_size=map_gib * 2**30)


def tree_names(env):
    """Named sub-databases, and the main-DB keys that are not any (the 08-24 damage)."""
    names, junk = [], []
    with env.begin() as tx:
        for k, _ in tx.cursor(db=env.open_db(None)):
            try:
                k.decode("utf-8")
            except UnicodeDecodeError:
                junk.append(k.hex())
            else:
                names.append(k)
    return names, junk


def main():
    src_path, out_path = sys.argv[1], sys.argv[2]
    map_gib = 32
    if "--map-size-gib" in sys.argv:
        map_gib = int(sys.argv[sys.argv.index("--map-size-gib") + 1])
    tmp_path = out_path + ".tmp"
    for p in (tmp_path, out_path):
        if os.path.exists(p):
            sys.exit(f"refusing to overwrite existing {p}")

    src = open_src(src_path, map_gib)
    names, junk = tree_names(src)
    print(f"source: {len(names)} trees, {len(junk)} non-UTF-8 main-DB keys (dropped): {junk}",
          flush=True)

    dst = lmdb.open(tmp_path, subdir=False, max_dbs=256, map_size=map_gib * 2**30,
                    writemap=True, map_async=True, metasync=False, sync=False)
    t0, counts = time.time(), {}
    for nm in names:
        sdb, ddb = src.open_db(nm), dst.open_db(nm, create=True)
        n, batch = 0, []
        with src.begin(db=sdb, buffers=True) as stx, dst.begin(db=ddb, write=True) as dtx:
            cur = dtx.cursor(db=ddb)
            for k, v in stx.cursor(db=sdb):
                batch.append((bytes(k), bytes(v)))
                n += 1
                if len(batch) >= BATCH:
                    cur.putmulti(batch, dupdata=False, overwrite=True, append=True)
                    batch = []
            if batch:
                cur.putmulti(batch, dupdata=False, overwrite=True, append=True)
        counts[nm.decode()] = n
        print(f"  {nm.decode():40s} {n:9d}", flush=True)
    dst.sync(True)
    dst.close()
    print(f"rebuilt {len(names)} trees / {sum(counts.values())} entries in {time.time()-t0:.0f}s",
          flush=True)

    # Compacting copy: right-sizes the file AND proves MDB_CP_COMPACT now succeeds, which is
    # exactly the operation garage's metadata snapshot worker performs.
    tmp = lmdb.open(tmp_path, subdir=False, readonly=True, lock=False,
                    max_dbs=256, map_size=map_gib * 2**30)
    t1 = time.time()
    tmp.copy(out_path, compact=True)
    tmp.close()
    print(f"compacting copy OK in {time.time()-t1:.0f}s -> "
          f"{os.path.getsize(out_path)/2**30:.2f} GiB "
          f"(source {os.path.getsize(src_path)/2**30:.2f} GiB)", flush=True)
    os.remove(tmp_path)

    # Verify the compacted result against the source, tree by tree.
    chk = open_src(out_path, map_gib)
    chk_names, chk_junk = tree_names(chk)
    out_counts = {}
    for nm in chk_names:
        db = chk.open_db(nm)
        with chk.begin(db=db) as tx:
            out_counts[nm.decode()] = tx.stat(db)["entries"]
    chk.close()
    src.close()
    bad = [(k, counts.get(k), out_counts.get(k))
           for k in sorted(set(counts) | set(out_counts)) if counts.get(k) != out_counts.get(k)]
    json.dump({"source_counts": counts, "rebuilt_counts": out_counts, "dropped_keys": junk},
              open(out_path + ".counts.json", "w"), indent=1)
    if bad or chk_junk:
        print(f"MISMATCH: {bad} junk={chk_junk}", flush=True)
        sys.exit(1)
    print(f"VERIFIED: {len(out_counts)} trees, {sum(out_counts.values())} entries, exact match",
          flush=True)


if __name__ == "__main__":
    main()
