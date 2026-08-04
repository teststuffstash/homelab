# The ghcr pull-through mirror filled four times in eight days

**Residual:** FU-093 (storage-tier ledger + metering — Longhorn per-disk usage is still unwatched,
which is why every one of these was discovered by a *consumer* failing rather than by the disk).

Written 2026-08-04, on the third-occurrence and cascade triggers. Three separate mechanisms filled
the same 20Gi PVC, each discovered only when the previous fix stopped being enough — and the first
occurrence fanned out into five peer issues in seventeen minutes.

## Timeline

| When (UTC) | What |
|---|---|
| 07-27 08:57 | **#45** `GithubWorkflowRunFailed` — oracle-fleet/devbox-cache. The first symptom; nothing connects it to storage. |
| 07-27 09:04 | **#46** `KubePodNotReady` — `sleep-tracking/agent-sleep-tracking-issue-36-r1` (an agent ride). |
| 07-27 09:05 | **#47** `KubePersistentVolumeFillingUp` — `mirror-ghcr-data` at **1.768% free**. The cause, filed 8 minutes *after* its first symptom and as a peer of it. |
| 07-27 09:09 | **#48** `KubePodNotReady` — `oracle-fleet/imagevol-kata-canary`. |
| 07-27 09:14 | **#50** `KubePodNotReady` — `oracle-fleet/oracle-fleet-ingester-riigiteataja-mcp`. |
| 07-27 09:16 | `cf2bb52` — PVC 10→20Gi. Eleven minutes from cause-alert to fix. |
| 07-27 10:43 | `3b166ba` — records that the bulk tier couldn't fit the expansion on wk-02, so the volume's replicas are co-located on wk-metal-01 by explicit choice. |
| 07-27 20:03 | It fills **again the same day**. The responder defers that alert into silence (own incident: [responder-silent-defer](2026-07-27-responder-silent-defer.md)); the operator wipes the cache by hand. |
| 08-02 21:11 | **#77** — ARC ephemeral runner pods stuck `Init:0/2` across both metal nodes. Probably this, unconfirmed (see Collateral). |
| 08-03 00:30 | **#80** — *"recurrence of #47, no GC in place"*. 9.8G of abandoned `_uploads` debris from a cold-pull herd (arc-runner, ~2.7G layer × N pods). |
| 08-03 07:54 | `43b0372` — upload purging at 1h (default was 168h) **+ an 85%-full early-warning alert**. |
| 08-03 08:04 | `519f9da` — the purge config panicked the registry: the maintenance block must be ONE env var holding a YAML map, not per-key vars. |
| 08-03 | `999234f` — CI pre-warms the mirror on runner-image pin PRs, shrinking the herd that caused the debris. |
| 08-03 18:34 | **#93** — the new 85% alert fires at **87%**, *before* anything broke. 17.1G, `_uploads` verified empty: this is neither capacity-guessing nor debris. |
| 08-04 06:45 | `639179b` — `registry garbage-collect` in an initContainer + the `gc-mirrors` CronJob to trigger it. |
| 08-04 06:48 | `c4b3570` — a failed collection prints a WARN instead of being swallowed. |
| 08-04 ~07:00 | Verified: docker-io `435 blobs marked, 87 blobs and 2 manifests eligible` → 2.4G→1.6G (8%); ghcr 15.4G (79%). |

## Root cause

**Three independent mechanisms, each masking the next**, on a store that had no eviction of any kind:

1. **Undersized** — 10Gi against the real working set (agent-base builds + the FU-096 devbox-cache
   artifacts). Fixed by capacity; held 7 days.
2. **Abandoned uploads never reaped** — concurrent cold pulls of a fat layer each stream into their
   own `_uploads/` dir; an ENOSPC truncation abandons them and the DEFAULT purge age of 168h left
   them wedging the disk for a week.
3. **No garbage collection at all** — `REGISTRY_STORAGE_DELETE_ENABLED=true` was set from day one
   (`b44ffb3`) and *nothing ever called* `garbage-collect`. Growth was unbounded by construction.

Nothing here was a wrong diagnosis. Each fix was correct and incomplete, and only the next
recurrence could show that.

**Ruled out, explicitly:**

- **#93 was not a repeat of #80's debris mechanism.** Every `_uploads` dir under
  `repositories/*/*/` was checked and found empty (4.0K, just the inode) *before* diagnosing —
  the 17.1G was entirely legitimate content-addressable blobs.
- **The 1.7G that disappeared when GC shipped was not GC.** That pod's own collection reported
  `0 blobs eligible`; the restart's proxy-scheduler `REGISTRY_PROXY_TTL` eviction reclaimed it.
  Attributing the drop to the new mechanism was the available wrong conclusion.
- **Not a Longhorn fault.** The volume was healthy throughout; the co-located replicas (`3b166ba`)
  are a deliberate trade, not degradation.

## Collateral

- **Five issues in 17 minutes across three namespaces** on 07-27 — `registry-cache` (the cause),
  `sleep-tracking` and `oracle-fleet` (symptoms), plus a CI build. Every symptom was an image pull.
- **The failure mode is not a clean error.** A full disk truncates in-flight proxy writes, so
  consumers see layer digest mismatches and 500s rather than "out of space" — which is why the
  symptoms look like four unrelated component failures.
- **#77 (ARC runners stuck `Init:0/2`, both metal nodes)** fired 3h18m before #80 and is plausibly
  the same store. Recorded as probable, **unconfirmed** — the pods were gone before anyone looked.
- **The docker-io sibling had silently never collected at all.** An aborted pull left
  `repositories/library/debian/` with `_manifests` and no `_layers`, and that one malformed
  directory fails the mark phase for the *entire* store. Cleared by hand 2026-08-04.

## Fixes

| Ref | What | Kind |
|---|---|---|
| `cf2bb52` | PVC 10→20Gi | **belt** — bought 7 days |
| `3b166ba` | record the co-located-replica trade | evidence, not a fix |
| `43b0372` | uploadpurging age 1h **+ 85% early-warning alert** | **root-cause** (mechanism 2) + the belt that made #93 arrive as a decision instead of an outage |
| `519f9da` | one YAML-map env var, not per-key | fix to the above (registry panicked) |
| `999234f` | CI pre-warms the mirror on runner-image pin PRs | belt — shrinks the cold-pull herd |
| `639179b` | `garbage-collect` in an initContainer + `gc-mirrors` CronJob | **root-cause** (mechanism 3) |
| `c4b3570` | failed collection is loud | observability of the fix |

GC runs in init because that is the only moment the store provably has no writer, and because both
ways of stopping a live registry — scale to 0, or flip `READONLY` — mutate a Deployment that ArgoCD
`selfHeal`s back mid-collection (confirmed live: a `kubectl apply` of that change was reverted
within seconds). The trigger is `kubectl delete pod`, which is not drift.

## Probe lesson

- **`KubePersistentVolumeFillingUp` at 3% free is too late for a pull-through cache.** By then it is
  already truncating writes. The 85% rule in `43b0372` is what converted the third occurrence into a
  capacity *decision* rather than an outage — the single most valuable line in this whole sequence.
- **Space dropping is not evidence that GC ran.** Read the `N blobs marked, M eligible` line; a
  restart alone reclaims via TTL eviction, and the two are indistinguishable from `df`.
- **A collection that fails on one malformed repo dir stops collecting the entire store**, and
  `|| true` makes that identical to success. Hence the loud WARN.
- **Verify the mechanism before inheriting the previous diagnosis.** #93 looked exactly like #80
  and was a different thing; the `_uploads` check took one command and decided it.
- **The cause and its symptoms arrive as peer alerts.** #47 was filed 8 minutes after #45 with no
  link between them, and the same PVC produced three top-level issues 8 days apart, each
  re-deriving the last one's context by hand. The alert lane files one issue per fingerprint and
  correlates nothing — the grouping design (a `subject:` key, and one issue per root cause with
  symptoms as evidence) is an open discussion, not yet an FU.
