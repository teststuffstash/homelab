# Spike — should the first-party registry move off the Garage S3 backend?

**Tracked by:** FU-280. **Touches:** [ADR-121](../adr.md) (the registry decision),
[ADR-089](../adr.md) (quota-as-contract), [`storage-ledger.md`](../storage-ledger.md) (who owns the
sum). **Status:** **DECIDED + CUT OVER 2026-09-24 14:50Z** ([ADR-121](../adr.md) amended): `registry-fs`
on the `registry-data` volume serves `registry.teststuff.net`, and the S3 Deployment runs unrouted as
the rollback. What remains is FU-280's soak and the S3 removal. How it got there: **re-framed 2026-09-24**. The cheap side-question was answered that day —
the 2× peak costs **zero disk**, so the quota argument is dead — but the operator's correction the
same day is that the quota refusal *was always the visible tip*: the case is **contention during the
release window and the machinery the S3 path drags in**, not capacity (§the real case). Next step is
therefore **phase 0**, a baseline of what a release costs the store's other tenants — **run the
same day, from 7 days of history: other tenants' p99 median is 9.5× worse while the registry
pushes, and the registry (not the pipelines beside it) is the variable that moves it.** The case is
measured; phase 1 is worth building. **Phase 1 was built and loaded the same day** (§Phase 1
RESULT): the 21 GB corpus copied cleanly at the 1 GbE rate, and the SN530 replicas were not the
limit. The operator then ordered the **rollout** (§Rollout): the live registry moves onto a
volume and keeps its name, and the headline is read at the first release after the flip. Opened 2026-09-22 after the second commit-refusal outage in
two weeks.

## The question

`registry.teststuff.net` ran `registry:3` on the **Garage S3 driver** until the 2026-09-24 cut-over. A blob commit on that driver
is two S3 steps — `CompleteMultipartUpload` of the upload, then a server-side **COPY** into
`blobs/sha256/…` — so between them the bucket holds the layer **twice** *in the quota's
accounting* (and, as of 2026-09-24, provably **not** on disk — §the side-question). Should it run on a
**filesystem (PVC)** backend instead, where a commit is a `rename(2)` and the double-hold does not
exist?

## What is established (measured, not argued — 2026-09-22, extended 2026-09-24)

- **The 2× peak is the proximate cause of both outages** — the *proximate* one; §the real case is
  the reason the spike exists. 09-09 and 09-22 were the same shape:
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
  **quota-accounting** effect only — which removes the capacity argument in *both* directions: the
  peak is not a reason to move, and disk savings are not a reason either.

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

### Phase 0 — BASELINE the release window first (detection before fix) — **DONE 2026-09-24**

The 2× claim is already settled and it was never the case. What phase 1 has to beat is
**contention**, and there is no point building a candidate before the thing it must improve is a
number. This is the repo's own doctrine — build the detector, let it read the real condition, then
change something — and it needs no new machinery: every series below already exists.

Over one **real** release window (oracle's corpus release; allure + Argo artifacts running
alongside), record:

| series | why |
|---|---|
| per-pod `PutObject` / `UploadPart` / `ListObjectsV2` p99, split by pod | the tenants the registry push is stealing IO from — the 4.86→6.94 s vs 0.07–0.59 s split is the shape to look for |
| `block_resync_queue_length` peak + drain time, per peer | the replication half of the cost, and the alert already watches it |
| table GC backlog + LMDB meta size, per peer, out to +24 h | the untag's tombstones do not land until `TABLE_GC_DELAY` has passed |
| `garage_write_probe_*` legs | the client-perspective view, already scraped every minute |

That baseline **is a deliverable on its own**: if the release window turns out to be invisible to
the other tenants, the case in §the real case is weaker than it looks and phase 1 is not worth
building. If it is visible, the same series are the acceptance test for phase 1.

#### Phase 0 RESULT (2026-09-24) — it is visible, and it is attributable

Prometheus keeps **31 d**, so this was answerable from history instead of waiting for a release.
**7 days, 2026-09-17 → 09-24, 1 969 five-minute samples.** "Registry pushing" = any sample with
`UploadPart`/`UploadPartCopy` traffic (the registry is the only multipart producer of this size);
"other tenants" = `PutObject`/`ListObjectsV2`/`GetObject`/`DeleteObject`, i.e. allure, Argo
artifacts, loki, transcripts, ert-snapshots. **The registry pushes in 123 of 1 969 samples —
6.2 % of the week, ~10 hours.**

**Other tenants' p99, split on whether the registry is pushing:**

| | n | median | p90 | p99 | mean |
|---|---|---|---|---|---|
| registry **pushing** | 123 | **4.72 s** | 12.6 s | 74.4 s | 7.86 s |
| registry **idle** | 1 846 | **0.50 s** | 1.35 s | 14.5 s | 1.35 s |

Median **9.5× worse**. Samples over 5 s: **41.5 % while pushing vs 4.2 % idle**. Over 30 s: 4.9 %
vs 0.6 %.

**And it is the registry, not the pipelines it runs alongside** — the load that matters is
isolated by splitting again on other-tenant request rate (median 1.29 req/s):

| registry | other tenants | n | median p99 | p90 | mean |
|---|---|---|---|---|---|
| pushing | quiet | 36 | 1.59 s | 58.4 s ⚠ | 13.9 s |
| pushing | busy | 87 | **4.94 s** | 9.30 s | 5.37 s |
| idle | quiet | 933 | 0.49 s | 0.92 s | 1.31 s |
| idle | busy | 913 | **0.52 s** | 2.76 s | 1.39 s |

**Other-tenant load on its own barely moves p99** (0.49 → 0.52 s median, 0.92 → 2.76 s p90 across
an order of magnitude more traffic). **The registry push is what moves it** — 0.49 → 4.94 s median.
That is the operator's thesis, measured: it is not the release *pipeline*, it is the registry's
bytes going through the shared store. ⚠ The 58.4 s p90 in the push/quiet cell is **noise-prone**
(n=36, and a low-count histogram lets a handful of stragglers dominate); the median column is the
load-bearing one.

**The lifecycle half moves too**, over the same split:

| series | pushing (median) | idle (median) | |
|---|---|---|---|
| `block_resync_queue_length` | **2 106** | 60 | **35×**. The idle figure independently reproduces the **median 58** that [`prometheusrule.yaml`](../../argocd/resources/garage-alerts/prometheusrule.yaml) records for the 7 days to 2026-09-22; **2 106 sits in that same file's p95 band (2.6 k)**. A routine push moves the fleet's resync backlog from its median to its 95th percentile. |
| `table_gc_todo_queue_length` | 115 107 | 80 151 | +44 % |

**That backlog has a measured operational consequence.** `garage:disruption_allowed` — the recording
rule that drives the `garage` PodDisruptionBudget, and therefore every `node-maintenance` drain of a
zone node — requires `max(block_resync_queue_length) <= 1000` among its three clauses. Split the
same way (smaller n: the rule only exists since the PDB shipped, 2026-09-22):

| | n | gate OPEN | gate CLOSED |
|---|---|---|---|
| registry **pushing** | 53 | 9.4 % | **90.6 %** |
| registry **idle** | 326 | 58.6 % | 41.4 % |

**While the registry is pushing, no Garage zone node can be drained** — the maintenance verbs refuse
and the reconciler retries. `GarageDisruptionBlocked` fires if that persists 2 h, and the same file
records the longest closed stretch in its own 7-day baseline as 82 min. So the registry's bursts do
not only cost the other tenants latency; they close the fleet's maintenance window on three nodes.

**Threat to validity, stated:** this is observational, not an A/B — "pushing" is inferred from
multipart traffic and the causal claim rests on the second table's control rather than on an
intervention. A single controlled release window (push held back, then released, same day) would
close it, and is cheap. It is not needed to justify building phase 1; it would be needed to claim
a precise factor.

### Phase 1 — the candidate, needs no DNS, cert or VIP

1. PVC on **`longhorn-bulk`** (the 2026-09-24 ruling; it is replica-2, which the availability
   requirement above needs). Planned at 40 Gi; **built at 150 Gi**, because size is what
   restricts it to the two SN530s (the arithmetic is in the ledger claim). The claim goes in
   [`storage-ledger.md`](../storage-ledger.md) per ADR-089's one hard rule even though it is
   temporary. ⚠ The measurement that matters most here is no longer the peak — it is **whether
   replica-2 across a 7600p and an SN530 binds on the slowest replica**; the ruling names
   `slow-bulk` as the escape hatch if it does.
2. `registry:3` Deployment, `REGISTRY_STORAGE=filesystem`, ClusterIP only, no auth front.
   ⚠ **`strategy: Recreate`** — RWO plus RollingUpdate deadlocks on the volume.
3. From an in-cluster pod: `skopeo copy` the real 10.6 GB corpus out of the current registry into
   it. Same payload, same cluster, one variable changed.

Measure against **phase 0's baseline**, not against the peak:

| measurement | Garage control | what would settle it |
|---|---|---|
| **other tenants' p99 during the push** (allure, Argo artifacts) | phase 0 | **unchanged from idle** — the release becomes invisible to them. *This is the headline.* |
| `block_resync_queue_length` + drain time attributable to the release | phase 0 | **zero** — the store never sees the bytes |
| table GC backlog / LMDB growth from the untag, out to +24 h | phase 0 | **zero** — the delete is an `unlink(2)` |
| bytes written + LAN bytes per release | ~31.8 GB, replicated over 1 GbE | ~21.2 GB, one inter-node copy |
| wall-clock to commit | ~9 min (2026-09-22, 20:04 → 20:12:57) | within noise, or better |
| **replica-2 across a 7600p and an SN530** | n/a | does the slowest-replica wait bind? `slow-bulk` is the named escape hatch (the 2026-09-24 ruling) |
| peak store usage during commit | 2 × layer **in the quota only**, 1 × on disk (measured 2026-09-24) | 1 × in both — a tidiness win, not the reason |

#### Phase 1 RESULT (2026-09-24) — the copy is clean and the SN530s are not the limit

A one-shot `skopeo copy --preserve-digests` Job on wk-01 (a wired node that holds neither replica)
pulled both tags out of the live registry and pushed them into the trial:

| | |
|---|---|
| payload | 2 tags × 1 layer × 10.51 GB = 21.0 GB (`ert-corpus:2026-09-22`, `:2026-09-23`) |
| wall-clock | **144 s + 140 s** (13:29:09Z → 13:33:53Z), ≈ **70 MiB/s** sustained per tag |
| integrity | manifest digests identical to the live registry's, both tags |
| client buffering | none: skopeo streamed registry-to-registry, and `/tmp` stayed at 1 MB |
| volume | `healthy` throughout; both replicas `running`, one per SN530 (hp-01, wk-04) |

**The slowest-replica question is answered: it does not bind at this rate.** Over the 4-minute
window, each SN530 wrote ≈ 71 MiB/s at **12 % (hp-01) and 7 % (wk-04) utilisation**. The 70 %-busy
`sdb` on wk-04 is the volume's iSCSI frontend, not a disk. The limit was the network: every hop read
≈ 78 MiB/s receive, the whole chain from the Garage source through wk-01 and wk-04 to hp-01, across
both hypervisors on 1 GbE. The SN530's 8–68 MiB/s sustained floor is a figure for writes that
outrun its SLC cache. It did not show up in 10.5 GB bursts at these utilisations, so `slow-bulk` is
not needed. (The pairing also differs from the one planned: sizing put the replicas on **two
SN530s**, not a 7600p and an SN530.)

**What this does NOT measure: the headline.** The copy *read* 21 GB out of Garage, which is the
opposite load from a release. On the trial side, a push that never touches Garage cannot contend
with Garage's tenants, so the "other tenants' p99" row holds by construction. What a real release
window still has to show is the trial handling the real pusher. ⚠ **As built, the real pusher cannot
reach it**: the oracle release pushes from a CI runner VM outside the cluster, and the trial is
ClusterIP-only. So "re-run phase 0 during a release" needs one of two things first:

- a temporary LB VIP on the trial (plain HTTP, like the live registry's in-cluster path), or
- phase 2's exposure.

**Neither was built. The operator's answer (2026-09-24) was to roll it out** (next section).

### Rollout — ordered 2026-09-24, in place of phase 2

"Just roll it out: copy the existing contents in, then repoint `registry.teststuff.net`." No new
name is needed. The hostname resolves to HAProxy `3.33` → LB `40.33` → the `registry` Service, and
the backend sits behind that Service's selector, so the naming trap below never arises.

1. **Stand up** `registry-fs` beside the S3 registry in ns `registry`
   ([`registry-fs.yaml`](../../argocd/resources/registry/registry-fs.yaml)). It gets the same
   nginx auth front, a 150 Gi `registry-data` claim (the trial's size, same selector arithmetic)
   and `RegistryVolumeAlmostFull` from creation. The trial is deleted to free the two SN530s.
2. **Copy** the corpus in with an in-namespace skopeo Job, authenticated with the existing
   `registry-push-token`, then **flip** the `registry` Service's selector to `app: registry-fs`.
   The GC CronJob moves to the volume in the same change. A delta copy after the flip catches
   any push that landed on S3 in between. **Rollback** = flip the selector back; the S3 registry
   keeps running.
3. **After the soak:** remove the S3 Deployment and the Garage bucket, and amend ADR-121.

**The headline is now read from the other side:** the first real release after the flip goes
to the volume. Re-run phase 0's queries across that window. The other tenants' p99 should
sit at its idle baseline.

### Phase 2 — SUPERSEDED by the rollout above (kept for the naming trap)

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

### What it settles, and what it does not

It settles one thing, cleanly and narrowly: **"the bucket holds the layer twice" is true of the
quota and false of the disk.** Consequences, in both directions:

1. **The 2× peak is not a capacity cost**, so it is not a reason to change backend — and "raise the
   cap" is a legitimate, nearly free way to stop *that* alert firing. A quota is a ceiling, not a
   reservation ([`garage-workspace.yaml`](../../argocd/resources/registry/garage-workspace.yaml):
   the 16 buckets' quotas already sum to ~205 GiB against 130 GiB of declared capacity).
2. **Equally, a PVC backend cannot be justified on disk savings.** The honest first-write comparison
   is ~31.8 GB (rf=3) against ~21.2 GB (replica-2) — **1.5×**, not 3×.
3. **FU-203 already caps the peak inside the existing 48Gi quota** (`2 kept + 2 × incoming =
   42.4 GB`, at any burst size), so the *outage* is addressable without this spike at all.

**What it does NOT touch is the case for the spike** — see §the real case below. The quota refusal
was the visible tip; the argument was never the 2×. What this measurement removes is **a bad
argument, not the argument**, and it was worth ten minutes to learn which: building on "it costs 2×
disk" would have sized the PVC by a rule that is simply false.

## The real case (operator, 2026-09-24): contention, and the machinery underneath

> *"Garage has a bigger cost on sync + deletion afterwards than Longhorn 2 replicas. It was more
> about the garage thrashing — oracle CI pipelines upload to S3 (allure) then argo pipelines read +
> write S3 + do a ghcr/registry push + untag the previous release + gc. Taking registry off S3
> reduces the S3 sync cost during that period."*
> *"Quota refusal was the visible tip of the iceberg — the complexity underneath was the problem."*

### 1. The release window runs two opposite workloads through one small store

A release is not an isolated event. In the same window: oracle CI uploads allure reports, the Argo
pipelines read and write S3 artifacts, the registry takes a ~10.6 GB push, the previous release is
untagged, and the collector runs. All of it on **three pods, three disks, one 1 GbE**.

The sixteen buckets, read live 2026-09-24:

| bucket | bytes | objects |
|---|---|---|
| `ert-snapshots` | 106.7 GB | 29 210 |
| **`registry`** | **21.0 GB** | **16** |
| `allure-reports` | 9.0 GB | **598 600** |
| `agent-transcripts` | 6.5 GB | 32 653 |
| `loki` | 4.5 GB | 252 934 |
| `oracle-specs` | 527 MB | 41 566 |

The registry and allure are **the two opposite extremes of the same store**: the registry is 14 % of
the bytes in **16 objects**; allure is **62 % of every object in the cluster** for 6 % of the bytes.
The release window runs both at once — a multi-GB block burst (disk, LAN, resync) against six
hundred thousand small-object metadata writes (the LMDB `object`/`version` tables). Each contends
for exactly what the other needs.

What contention costs here is already measured in this document, not argued: a Garage node busy
serving a rebuild ran PutObject p99 **4.86 → 6.94 s while its two peers stayed at 0.07–0.59 s**
(§the rotation table, 2026-09-12), and under an oracle delta run `UploadPart` p99 reached **27 s**
and `ListObjectsV2` **35.7 s** on garage-0. The mechanism is not the quota; it is one small store
doing everyone's IO at once.

### 2. The write is the cheap half — sync and deletion are the rest

| | Garage (rf=3, shared) | Longhorn `longhorn-bulk` (replica-2, dedicated) |
|---|---|---|
| first write | ~31.8 GB | ~21.2 GB |
| replication | every block to 3 nodes over the same 1 GbE, via the resync queue | one extra replica, then nothing |
| delete (untag) | tombstones that **table GC pushes to EVERY node and holds for `TABLE_GC_DELAY` = 24 h** ([`prometheusrule.yaml`](../../argocd/resources/garage-alerts/prometheusrule.yaml)), then block GC walks and decrements refcounts | `unlink(2)` inside the volume's own filesystem |
| metadata | `object`/`version`/`block_ref` rows ×3 plus Merkle trees, in an LMDB that **ratchets** (~2.6 GB/day of leaked pages, with *zone rotation* — a 2 h+ operation — as the standing remedy) | none |
| who else pays | every other tenant on the store | nobody |

Loose ends the S3 lifecycle has produced on this bucket alone: **FU-279** (incomplete multipart
uploads `garbage-collect` never walks — 4.3 GB stuck, and the reclaim command carries a ☠ from the
[2026-08-24 postmortem](../incidents/2026-08-24-pve-thin-pool-garage-meta-wipe.md)).

### 3. The machinery that exists ONLY because the store is S3

| machinery | exists because |
|---|---|
| the `quota − held ≥ 2 × largest layer` rule, re-derived at 20Gi → 32Gi → 48Gi | a commit is a two-step COPY on the S3 driver |
| `RegistryBucketCommitHeadroomLow`, fed by the garage-meta-rotation controller pushing the admin-API counter every 15 min | Garage exports no per-bucket size metric, so nothing else can see a cap |
| the untag → collect schedule alignment (02:30Z → 03:00Z), three alert firings to get right | prune and GC are two systems in two repos (the ADR-085 split) |
| FU-279's uncollectable multipart debris | multipart uploads onto a content-addressed refcounted store |
| the opaque **500** — ADR-089 promises "fails fast with a legible error"; here it fails slow, at commit, illegibly | the registry maps Garage's 403 onto 500, and `api_s3_error_counter` does not move |

On a PVC the commit is a `rename(2)`, the cap is `df`, the prune is `registry garbage-collect` over
local files, and an over-cap write fails with `ENOSPC`. **Most of that table stops existing.** That
is the case, and it is an argument about *complexity and blast radius*, not about capacity.

## What this does NOT decide

The failure that triggered it is **not** fixed by any of the above. The bucket blew up holding a
keep-set of 3 while pushing a 4th, because oracle-fleet untags *after* a release — the prune used to
be the first step of `release-corpus.yaml` "before the weekly push" and ADR-OF-004 moved it to a
nightly cron. Prune-before-push caps the peak at `2 kept + 2 × incoming = 42.4 GB` **at any burst
size**, on the current backend, with no capacity spend. That ordering fix and a pre-flight headroom
gate were cheaper and more urgent than this spike, and shipped under FU-203 (the retention untag + the
daily collector; archived 2026-09-24).
