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
2. **`lmdb-carve.py <layer.img> <outdir> <bucket-id-hex>…`** — scans the raw layer image and writes
   `objects.jsonl` + `versions.jsonl`. ext4's block size equals LMDB's page size, so every DB page
   is one aligned 4 K block and the scan needs no b-tree walk and no filesystem: it classifies pages
   by their LMDB header and reads the leaf nodes directly. Values larger than a page live on
   overflow pages, which is why the scan also indexes `pgno → image offset` (each page header
   carries its own page number).
3. **`restore-from-blocks.py work.jsonl report.jsonl`** — runs INSIDE the cluster
   (`forensics-pod.yaml`), reassembles each object from its blocks and PUTs it back. Stdlib only:
   SigV4 is 40 lines and beats depending on pip inside a pod.
4. **`verify-restored.py work.jsonl failures.jsonl`** — HEADs every key over a *different* path
   (the LAN endpoint, not the in-cluster Service) and compares size + ETag against the carved
   metadata, so a shared-fate bug in the writer cannot hide a bad object.

`carve-one.py` pulls a single object out to a local file without writing to S3 — the right tool when
what you need is one lost `terraform.tfstate` rather than a bucket.

## What the records look like (Garage v2.3.0)

Table rows are `<version marker><msgpack named map>`, and the marker is what makes a stale page
attributable when there is no b-tree to walk:

| Marker | Table | LMDB key |
|---|---|---|
| `G2s3ob` | object | `<32B bucket id><object key>` |
| `G09s3v` | version | `<32B version uuid>` |
| *(none)* | block_ref | `<32B block hash><32B version uuid>` |
| *(none)* | merkle tree | short; value is `{"Leaf"\|"Intermediate": …}` |

Garage `Uuid` is **FixedBytes32**, not a 16-byte UUID — version keys are 32 bytes. An object row
carries its versions; a `Complete` one is either `Inline` (payload embedded in the metadata, so it
needs no blocks at all) or `FirstBlock` (+ the version row's ordered block list). Response headers
live at `meta.encryption.Plaintext.inner.headers`; `Plaintext` also means the blocks are plain zstd,
which `SSE`-encrypted buckets would not be.

Bucket ids are the OLD ones, and the alias table may not have survived — group object rows by their
32-byte prefix and identify buckets from the key shapes instead.

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
