# 2026-08-31 — the Argo lock plane wedged: GC'd workflows leak their sync locks

**Impact:** the coordinate lane stalled from ~11:08Z: the `subscription-capacity/claude`
semaphore read **5/5 held with zero live holders** and the `coordinator-scan` mutex was held
by a deleted workflow, so every coordinate tick queued behind locks nobody could release —
**56 `coordinate-*` workflows Pending** in `agent-coordinator` by 12:10Z, ~1 workflow
actually running fleet-wide. Discovered by the operator on the agent-running dashboard
(pending count climbing) cross-read against the subscription-headroom panel
(`anthropic_subscription_semaphore_running` = 1 vs max 5) — no belt fired.

## Root cause

Argo Workflows' **gc_controller deletes workflows without releasing their sync locks**.
Directly observed for the mutex: controller log 12:08:24Z
`Deleting garbage collected workflow … coordinate-dn8p7` — and every waiter thereafter named
`agent-coordinator/coordinate-dn8p7` as the holder of `Mutex/coordinator-scan` while the CRD
was gone. The claude semaphore's 5 phantom holders are the same shape from earlier GC cycles
(no live workflow carried `status.synchronization.semaphore.holding` at 12:14Z, yet the lock
read 5/5). The controller's in-memory sync state (pod up 5d18h) had diverged permanently from
the live CRDs: a slot held by a nonexistent workflow is never reclaimed. Upstream bug class;
`workflow-controller:v4.0.7`.

## Fix

`rollout restart` of `argo/argo-workflows-workflow-controller` at 12:15:38Z — on boot the
sync manager rebuilds lock state from live workflow statuses only. Mutex freed, semaphore
slots re-acquired by real runners (4/5 within a minute), backlog drained 56→3 Pending by
12:19Z. The one Running workflow (`iac-sentinel-edge-rdx8d`) rode through untouched.

## Why nothing alerted (the belt audit)

- `AgentQueueStalled` watches `agent/queued` labels × worker pods × open PRs — this wedge is
  **upstream of dispatch** (the coordinate ticks themselves queued), and its zero-open-PRs
  conjunct suppresses it on any normal day regardless.
- `argo-workflows-alerts` holds exactly one alert (controller memory) — nothing reads
  workflow phase counts.
- The divergence WAS in metrics the whole time — the proxy's server-side
  `anthropic_subscription_semaphore_running` (real pods: 1) vs Argo's lock view (5/5) — but
  nothing compares them, and no rule watches Pending pileup.

Residual (the belt): FU-198.
