# Spike — should the first-party registry move off the Garage S3 backend?

**Tracked by:** FU-280. **Touches:** [ADR-121](../adr.md) (the registry decision),
[ADR-089](../adr.md) (quota-as-contract), [`storage-ledger.md`](../storage-ledger.md) (who owns the
sum). **Status:** open — but its premise is now **measured and substantially weaker**: the cheap
side-question below was answered 2026-09-24 and the 2× peak turns out to cost **zero disk**. What is
left is an operator fork, not a build. Opened 2026-09-22 after the second commit-refusal outage in
two weeks.

## The question

`registry.teststuff.net` runs `registry:3` on the **Garage S3 driver**. A blob commit on that driver
is two S3 steps — `CompleteMultipartUpload` of the upload, then a server-side **COPY** into
`blobs/sha256/…` — so between them the bucket holds the layer **twice** *in the quota's
accounting* (and, as of 2026-09-24, provably **not** on disk — §the side-question). Should it run on a
**filesystem (PVC)** backend instead, where a commit is a `rename(2)` and the double-hold does not
exist?

## What is established (measured, not argued — 2026-09-22, extended 2026-09-24)

- **The 2× peak is the proximate cause of both outages.** 09-09 and 09-22 were the same shape:
  quota refused the COPY's commit, the registry mapped Garage's 403 onto an opaque **500**, and the
  pusher saw a 10 GB upload die at its last byte (51 min on 09-08, 10 min on 09-22).
- **The arithmetic, reproduced exactly.** Held 31.6 GB (3 tag-served blobs) → upload completes
  42.2 GB → copy needs 52.7 GB → refused at a 51.5 GB quota. Every figure matched the live gauge.
- **Successive corpus layers share nothing.** 09-15 `c05de1fa`, 09-17 `3d5179da`, 09-22 `32bca6c0`,
  09-22bis `5fe97e67` — four distinct ~10.5 GB blobs plus ~29 KiB configs. The corpus is one
  uncompressed tar layer and the delta is "patch-then-rebuild", so no two releases can dedupe at
  the layer level.
- **The registry is NOT canonical, but IS the outage insurance.** The release dual-pushes ghcr
  (canonical/offsite) and the LAN registry, so the store is *rebuildable* — but rebuilding it
  requires ghcr, which is one of the things ADR-121 exists to be independent of (429 storms,
  mid-stream `PROTOCOL_ERROR`, the #1282 poisoned-mirror commit). **Recovery that depends on the
  thing you are insuring against is not recovery**, which rules out a replica-1 store on
  availability grounds even though rebuildability would otherwise permit it (operator, 2026-09-22).
- **A category error is what kept this closed.** ADR-121 rejected the PVC backend with two clauses:
  "bulk tier 88% committed" (a real capacity fact in September) and "corpus is data → S3,
  CONTEXT.md #1". The second does not reach this question: CONTEXT.md #1 is about **boot-from-git
  recoverability of data**, which the corpus already satisfies in the pipeline (staged on Garage,
  `corpus-image.oci.tar` is its Garage transport form, Argo artifact passing rides it). The
  registry's *backing store* is a service's working store, a different thing (operator,
  2026-09-22). The nearest precedent points the other way: the pull-through mirrors are rebuildable
  and sit on **PVCs** by decision ([ADR-091](../adr.md) — "cache PVCs on longhorn-bulk"), with
  "bigger PVC, never a lower threshold" as the recorded posture
  ([`storage-ledger.md`](../storage-ledger.md), homelab#116).
- **Writes per release, if the backend changed** — a PVC at 2 replicas writes ~21.2 GB, against
  Garage rf=3's **~31.8 GB**. The ~63.6 GB alternative is **ruled out by measurement** (2026-09-24,
  below): the server-side COPY shares blocks, so it writes nothing. The candidate is therefore
  cheaper in writes by **~1.5×**, not 3×.
- **The 2× commit peak costs NO disk** (measured 2026-09-24, §the side-question). It is a
  **quota-accounting** effect only. This removes the capacity half of the case for changing
  backend — the half that made it urgent.

## WHICH TIER — ANSWERED 2026-09-24: `bulk`

> **Operator ruling, 2026-09-24 — "I dont want to have a storageclass and tier name per each nvme
> drive I happen to have."** `registry2` is a **`bulk`** workload, not a new tier; the two WD SN530s
> fitted that day join `bulk` and take it from 91.5 % committed to 61 %, which dissolves the
> capacity objection below. The full ruling, including how the `bulk` row's *second* objection
> (wipe-on-PXE) is answered, lives in [`storage-ledger.md`](../storage-ledger.md) §the operator
> ruling of 2026-09-24 — it is placement, so it belongs there and not in an ADR (§2026-09-07).
> The rest of this section is the reasoning that led there; the table's `against` column is what
> the ruling had to answer.

### The reasoning, as it stood on 2026-09-22

**`std` is not the answer** (operator, 2026-09-22). It is fine to *start* a spike on, and it has the
room today — hp-01 `intel7600p` 227 G avail, m70s `nvme` 295 G — but ADR-089 defines `std` as "the
original small always-on disks", and **this store must be sized for hundreds of GB**: first-party
artifacts, a corpus that went 6.4 → 10.6 GB in three weeks, and FU-274's ambition to move our own
images off the ghcr mirror onto it.

At that size the replica multiplier is the whole decision — 300 GB at 2 replicas is 600 GB of
committed tier, on a fleet whose entire `bulk` tier is 902 G allocatable and already 90 % committed.
Candidates, none yet costed:

| candidate | for | against |
|---|---|---|
| `bulk` (wk-metal-01 MX500, wk-metal-04 intel0/intel1) | the big disks; its tier definition ("rebuildable, degradation on wipe acceptable") matches this store's profile exactly | 90 % committed already, and the registry mirrors are its biggest tenant; wipe-on-PXE laptops |
| `slow-bulk` (wk-metal-04 `sata500`) | **478 G raw, 391 G avail, 0 scheduled — idle today**; a registry is sequential and network-bound (1 GbE ≈ 125 MB/s caps far below this disk) | deliberately unschedulable today; replica-1 by shape unless a second such disk joins |
| dedicated storage-tier disks | the fleet-roles direction (SFFs = storage zones) and FU-137's residual already point here | does not exist yet; a purchase |
| node-local (`longhorn-local-*`, replica 1) | no multiplier at all | `strict-local` pins the pod; replica 1 conflicts with the availability requirement above |

**This is the part to decide before building anything permanent**, and it is ADR-shaped: it changes
what `bulk`/`slow-bulk` are *for*, so it belongs with the fleet-roles and FU-137 conversation rather
than inside a registry PR.

## The experiment

### Phase 1 — settles the 2× claim, needs no DNS, cert or VIP

1. PVC, 40 Gi (two layers + one in flight), on **`longhorn-bulk`** (the 2026-09-24 ruling; it is
   replica-2, which the availability requirement above needs). The claim goes in
   [`storage-ledger.md`](../storage-ledger.md) per ADR-089's one hard rule even though it is
   temporary. ⚠ The measurement that matters most here is no longer the peak — it is **whether
   replica-2 across a 7600p and an SN530 binds on the slowest replica**; the ruling names
   `slow-bulk` as the escape hatch if it does.
2. `registry:3` Deployment, `REGISTRY_STORAGE=filesystem`, ClusterIP only, no auth front.
   ⚠ **`strategy: Recreate`** — RWO plus RollingUpdate deadlocks on the volume.
3. From an in-cluster pod: `skopeo copy` the real 10.6 GB corpus out of the current registry into
   it. Same payload, same cluster, one variable changed.

Measure, against tonight's Garage numbers as the control:

| measurement | Garage control (2026-09-22) | what would settle it |
|---|---|---|
| peak store usage during commit | **2 × layer** (42.2 → 52.7 GB attempted) | **1 × layer**, i.e. no double-hold |
| wall-clock to commit | ~9 min (20:04 → 20:12:57) | within noise, or better |
| bytes written per release | **~31.8 GB** (rf=3; block sharing confirmed 2026-09-24) | ~21.2 GB at 2 replicas |

### Phase 2 — only if phase 1 wins

Exposure as a real name, because the consumer mounts the image as a **native OCI image volume**
(`chart/templates/mcp-server.yaml`) which containerd pulls, and ADR-121's "zero node config, no
insecure-registry anywhere" constraint means a genuine pull test needs HAProxy VIP + Unbound
override + LE cert — the [`opnsense-as-code`](../runbook.md) path, with a new address from
[`ip-plan.md`](../ip-plan.md). Proves nothing phase 1 has not, so it waits.

⚠ **Naming:** a `registry2.teststuff.net` would be a throwaway name that outlives the throwaway. If
the PVC backend wins, the end state is that it *becomes* `registry.teststuff.net`. Either commit to
the temporary name being deleted, or skip the hostname until the cutover. A permanent new name would
need a [glossary](../glossary.md) row in its coining commit (FU-163); the glossary currently holds
only **registry (first-party)** and **registry mirrors**.

## The cheap side-question — ANSWERED 2026-09-24: the COPY shares blocks, and costs zero disk

**It shares them.** The 2× peak is a **quota-accounting artifact costing no disk whatsoever.**

**Method** (live cluster, ~10 min): throwaway bucket `copytest` + key, quota raised to 8 G, and
**256 MiB of `/dev/urandom`** so the payload shares no content with anything already stored. PUT
from an in-cluster pod on `wk-04` with `aws s3 cp` — the same multipart path the registry uses.
The instrument is `garage stats`: *"number of RC entries (~= number of blocks)"* for the block
store, per-node `DataAvail` for actual disk, and `bucket info` **Size** for what the quota counts.

| step | bucket Size (what the quota sees) | RC entries (blocks) | `DataAvail` m70s / wk-metal-01 / wk-metal-04 |
|---|---|---|---|
| baseline | 0 | 485 487 | 73.1 / 72.4 / 72.5 GiB |
| **idle control, 75 s** (sizes the noise) | 0 | **+13** | 73.1 / 72.4 / 72.5 — unchanged |
| PUT 256 MiB | 256 MiB | **+257** | 72.8 / 72.4 / 72.3 — **falls** |
| `CopyObject` a → b | **512 MiB** | **+1** | 72.8 / 72.2 / 72.3 |
| 8 more copies (a → c…j) | **2.5 GiB, 10 objects** | **+2 total** | 72.8 / 72.2 / 72.3 — **unchanged** |

Ten objects, 2.5 GiB of logical bytes the quota charges for, **one physical copy**. Duplicating
them would have cost ≈2 GiB *per zone* and the print granularity is 0.1 GiB, so the negative is not
a rounding artifact. `block_ref` grew with each copy (new version rows) while RC did not — the new
versions point at the **same** blocks.

⚠ **One confounder, named because RC entries alone do not settle it.** Garage's block store is
content-addressed globally, so a COPY that genuinely *re-wrote* identical bytes would dedupe to the
same hashes and also leave RC flat. **`DataAvail` is what settles it**, and it did not move across
2 GiB of logical copies. Either way the operational conclusion is identical: *no disk is consumed*.

### What this changes

1. **The capacity argument for the PVC backend is gone.** It was the urgent half — "the bucket holds
   the layer twice" is true of the *quota* and false of the *disk*.
2. **Write amplification is 1.5×, not 3×** — Garage rf=3 writes ~31.8 GB per release against a
   replica-2 PVC's ~21.2 GB. A real cost, not a failure mode.
3. **"Raise the cap" is now nearly free.** A quota is a ceiling, not a reservation
   ([`garage-workspace.yaml`](../../argocd/resources/registry/garage-workspace.yaml) header: the 16
   buckets' quotas already sum to ~205 GiB against 130 GiB of declared capacity), and the transient
   half of the registry's cap now provably buys nothing physical.
4. **FU-203 already caps the peak without spending anything.** Prune-before-push holds it at
   `2 kept + 2 × incoming = 42.4 GB` — **inside the existing 48Gi cap**, at any burst size.
5. **What survives of the case for changing backend:** the opaque **500** (a legibility bug, and
   ADR-089's "fails fast with a legible error" promise is broken on this path regardless of
   backend), FU-274's ambition to serve first-party images from here, and that 1.5×.

**Therefore this is an operator fork, not a build.** Neither branch is blocked on capacity any
more, and the tier question that used to block it was answered independently the same day
(`bulk` — [`storage-ledger.md`](../storage-ledger.md) §the operator ruling of 2026-09-24).
Phase 1 below is still the right experiment *if* the fork goes that way; it is no longer the
obvious next step.

## What this does NOT decide

The failure that triggered it is **not** fixed by any of the above. The bucket blew up holding a
keep-set of 3 while pushing a 4th, because oracle-fleet untags *after* a release — the prune used to
be the first step of `release-corpus.yaml` "before the weekly push" and ADR-OF-004 moved it to a
nightly cron. Prune-before-push caps the peak at `2 kept + 2 × incoming = 42.4 GB` **at any burst
size**, on the current backend, with no capacity spend. That ordering fix and a pre-flight headroom
gate are cheaper and more urgent than this spike; see FU-203.
