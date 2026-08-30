# garage-forensics — recovering objects from Garage after a metadata loss

Written during the 2026-08-24 incident
([postmortem](../../docs/incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md), homelab#884),
where Garage's metadata LMDB came back **empty-tabled** while all 55 GB of content-addressed data
blocks survived. The durability answer is ADR-114 ([`docs/garage.md`](../../docs/garage.md)
§Durability) — this directory is the *other* half: what to do when it has already happened.

**The premise: blocks outlive metadata.** A block whose *reference count* drops to zero is GC'd on a
timer by Garage itself (observed ~10 min after the last version referencing it was replaced) — but a
block the metadata no longer knows about at all has no rc entry to drop, and those are reaped only
by a MANUAL `garage repair blocks`. A metadata wipe produces exactly the second kind: after it, the
objects are still on disk and what is missing is the map from key → block hashes. That map is
recoverable because LMDB is copy-on-write: emptying the tables leaves the old pages in place until
their page numbers are reused.

## The chain

1. **Freeze the evidence first.** Longhorn snapshot of the data volume, and copy the meta volume's
   replica layers off the node. Do NOT run `garage repair blocks` (or `block-refs` / `block-rc`)
   until the carve is finished — the auto-scrub is verify-only and safe.
2. **`lmdb-carve.py <layer.img> <outdir> [<bucket-id-hex>…]`** — scans the raw layer image and
   writes `aliases.json` + `objects.jsonl` + `versions.jsonl`; with no bucket ids it carves every
   bucket the alias table names. ext4's block size equals LMDB's page size, so every DB page
   is one aligned 4 K block and the scan needs no b-tree walk and no filesystem: it classifies pages
   by their LMDB header and reads the leaf nodes directly. Values larger than a page live on
   overflow pages, which is why the scan also indexes `pgno → image offset` (each page header
   carries its own page number). Records are spooled to disk and only the winning line per key is
   kept, so a whole-store carve stays inside a few hundred MB of RAM.
3. **`build-work.py <carve-dir> work.jsonl [--only|--exclude a,b] [--live <dir>] [--since ms]`** —
   joins objects to their version rows, resolves bucket ids to names, drops everything that was not
   a `Complete` version, and (with `--live`) skips keys that are already back, so the run is the
   delta rather than a million no-op HEADs.
4. **`restore-from-blocks.py work.jsonl report.jsonl`** — runs INSIDE the cluster
   (`forensics-pod.yaml`), reassembles each object from its blocks and PUTs it back. Stdlib only:
   SigV4 is 40 lines and beats depending on pip inside a pod. `PRESCAN=1` stats the blocks without
   reading or writing anything — run it first on a big carve, it answers "how much of what the
   metadata names is still on disk" in under a minute.
5. **`verify-restored.py work.jsonl failures.jsonl`** — HEADs every key over a *different* path
   (the LAN endpoint, not the in-cluster Service) and compares size + ETag against the carved
   metadata, so a shared-fate bug in the writer cannot hide a bad object.

`carve-one.py` pulls a single object out to a local file without writing to S3 — the right tool when
what you need is one lost `terraform.tfstate` rather than a bucket.

## The other repair: `lmdb-rebuild.py` (a live env, not a wipe)

The chain above recovers objects from an env that lost its tables. `lmdb-rebuild.py <src data.mdb>
<out data.mdb>` fixes the *opposite* damage: an env that still serves fine but is structurally
unfit — pages leaked, so the file grows without bound and **every** LMDB compacting copy is
rejected, which is exactly what `metadata_auto_snapshot_interval` performs. Symptom in the Garage
log, once per attempt, forever:

```
ERROR garage_util::background::worker: Error in worker Metadata snapshot worker (TID 59):
      DB error: LMDB: MDB_INCOMPATIBLE: Operation and DB incompatible, or DB flags changed
```

LMDB decides this by arithmetic, not by reading your data: it predicts the compacted root as
`next_pgno - 1 - freecount` and returns `MDB_INCOMPATIBLE` when the walk lands elsewhere
(`mdb.c`: `/* page leak or corrupt DB */`). So no *copy* can fix it — the copy is what the leak
disqualifies — and `garage convert-db` cannot either: it rejects `lmdb`→`lmdb` ("input and output
database engine must differ"), and the same damage can leave raw freelist records in the main
database, which kills its `list_trees()` on a UTF-8 decode before it starts. This script re-inserts
every named tree in key order (append mode packs the leaves), skipping non-UTF-8 main-DB keys, then
takes the compacting copy of the result — which now succeeds, right-sizes the file, and is itself
the acceptance test for the snapshot belt. It exits non-zero unless every tree's entry count
matches the source.

Needs `pip install lmdb`; Garage must be stopped, and the meta volume is the ONLY copy — take a
Longhorn snapshot and a verified off-cluster copy of `data.mdb` first. **Run it on a host copy**:
the rebuild reads hundreds of thousands of scattered 4 KiB pages, which over a network-attached
Longhorn volume is ~0.3 MB/s against ~100 MB/s for a sequential `cat` of the same file — copy out,
rebuild, push the (much smaller) result back. Live run 2026-08-25, homelab#884 / FU-184:
18.10 GiB → 1.57 GiB, 67 trees / 4,279,175 entries, exact match. Afterwards check that the
container's memory limit still exceeds the DB size — a snapshot that starts *completing* writes
its whole copy in seconds, and the first one OOM-killed Garage at 512Mi.

## What the records look like (Garage v2.3.0)

Table rows are `<version marker><msgpack named map>`, and the marker is what makes a stale page
attributable when there is no b-tree to walk:

| Marker | Table | LMDB key |
|---|---|---|
| `G2s3ob` | object | `<32B bucket id><object key>` |
| `G09s3v` | version | `<32B version uuid>` |
| *(none)* | bucket_alias | `<32 zero bytes><global alias>`; value `{name, state:{ts, v: <32B bucket id>}}` |
| *(none)* | block_ref | `<32B block hash><32B version uuid>` |
| *(none)* | merkle tree | short; value is `{"Leaf"\|"Intermediate": …}` |

Garage `Uuid` is **FixedBytes32**, not a 16-byte UUID — version keys are 32 bytes. An object row
carries its versions; a `Complete` one is either `Inline` (payload embedded in the metadata, so it
needs no blocks at all) or `FirstBlock` (+ the version row's ordered block list). Response headers
live at `meta.encryption.Plaintext.inner.headers`; `Plaintext` also means the blocks are plain zstd,
which `SSE`-encrypted buckets would not be.

Bucket ids in the carve are the OLD ones — Crossplane re-minted every bucket with a new id after
the wipe, so nothing in the live store matches them. Recovering the *names* is what `aliases.json`
is for: the bucket_alias rows carve out of the same pages, keyed by `<32 zero bytes><name>`, which
is why a first attempt looking for the bare name as the key finds nothing. That table survived
intact in the 2026-08-24 wipe (all 14 buckets); the fallback if it ever does not is to group object
rows by their 32-byte prefix and identify buckets from the key shapes.

A multipart object's version row carries a `part_number` per block. That is worth more than
ordering: replaying the original part boundaries through a multipart upload reproduces the stored
`<md5-of-part-md5s>-<n>` ETag exactly, so a >RAM object can be restored *and* proven byte-identical
without ever holding it whole (`restore-from-blocks.py` does this for anything over `MAX_BODY`).

## Operational notes

- The data PVC is RWO, which is a **node**-level lock: a second pod pinned to the Garage pod's node
  mounts the same claim read-only. No host paths, no privilege. Delete it afterwards — a
  `nodeName`-pinned second mounter would pin the volume to that node.
- `python:3.14-slim` carries stdlib `compression.zstd`, so the pod needs no pip.
- The Garage image has no shell and no coreutils; `kubectl exec garage-0 -- /garage …` is the only
  thing that runs in it.
- The restore **never overwrites an existing key** — anything written after the incident wins.
  That rule has a tail: mutable singletons (a ledger, a state snapshot) that were restored from an
  older backup exist, so they are skipped, and they stay regressed. The verify pass is what finds
  them; merge those by hand.
