# ARC runner memory budget — a node-sized limit, not node removal

**Tracked by:** FU-218. **Status:** open — option A (below) chosen for a spike (operator,
2026-10-02); no ADR yet. Pool measurements live in
[`ride-latency-breakdown.md`](ride-latency-breakdown.md) §CI side; the kata side in
[`kata-ci-gate.md`](kata-ci-gate.md).

## The recurring shape

Since the start of the ARC pool the same loop repeats: a heavy job kills or evicts a runner on an
8 GB node → pressure to move runners off the 8 GB nodes → a workload fix → the job runs fine on
8 GB again. History (from FU-218):

- 2026-09-05: queue p90 ~10 min with the `maxRunners` cap hit 0–2 % of the time — placement, not
  slots (a ~2.5 Gi request = one runner per 8 GB laptop).
- 2026-09-08 (PR#1518): wk-03 8→16 Gi / 12 c, `maxRunners` 4→6. 2026-09-14 (PR#1671, operator):
  back to 8 Gi / 6 c, `maxRunners` 6→4 — pve sat at 0.5–1 GiB MemAvailable.
  Left open then: (a) label wk-metal-04 `homelab.io/ephemeral` ≈ +3–4 slots shared with kata
  (operator call); (b) re-read the queue p90 at operator hours (07–09/17–19 UTC) — close if under ~2 min.
- 2026-09-10 (#1582): `homelab-ephemeral-large` (metal-only, 16 Gi scratch, max 1) — its template
  is a COPY of the general one.
- 2026-09-28: a 1536 Mi-request runner thrashed wk-03 past its kubelet — hard reset,
  [incident](../incidents/2026-09-28-wk-03-runner-memory-thrash.md); the same container's 7-day
  working-set peak 20–23.5 GiB, all on nx-01.
- 2026-10-02: oracle-fleet #783's `ci` lost twice on wk-03 — kubelet eviction, no log, job
  "failed" at 11:00 (oracle handoff `20261002-1815-arc-runner-memory-request-vs-peak.md`).

## Why: the runner never tells the job its budget

The runner pod requests 1536 Mi with **no limit**. Inside the container `nproc` and MemAvailable
are the whole HOST's, so self-sizing tools size to the host. `pytest -n auto` starts one xdist
worker per CPU, and memory follows the worker count (~0.5–0.85 GiB/worker):

| Run (oracle-fleet #783) | Node (cores) | Workers | Runner peak | Result |
|---|---|---|---|---|
| successful runs | nx-01 (40) | 40 | 20–21.5 GiB | pass, ~2 min |
| b856e83 attempt 2 | wk-03 (6, allocatable 6.0 GiB) | 6 | 5.1 GiB and rising at 1 min | evicted |
| a6d47a4 (xdist capped by MemAvailable − 1 GiB, 1280 MiB/worker) | wk-metal-03 (4) | 3 | 3.1 GiB | pass, 7.5 min |

**The jobs fit on 8 GB once parallelism is bounded.** Oracle's cap is a stack-side fix only: its
MemAvailable snapshot races co-tenants, wk-03's budget (~5.1 GiB) sits right where attempt 2 was
evicted, an overrun still vanishes without a log, and every other stack's parallel job repeats it.

## Options (2026-10-02)

The cluster (v1.36.1) serves `pods/{name}/resize` (in-place pod resize). Runner pods are a single
unprivileged `runner` container under a no-permission service account.

| Option | The node sets the budget by | Verdict |
|---|---|---|
| **A. Resize after binding** | a small controller watching `arc-runners` pods: once bound, budget = node allocatable − other pods' requests − headroom, patched onto the pod's `resize` subresource (request AND limit). `memory.max` becomes the node-sized budget — oracle's `ci.sh` already reads it first | **chosen for the spike** — works on runc today; only the controller needs `pods/resize`; a request raise the node cannot fit is deferred, not overcommitted |
| B. Per-node kata VM size | kata's per-node `default_memory`/`default_vcpus` for a limit-less pod — inside the guest `nproc`/MemAvailable ARE the budget, so even plain `-n auto` is right | later: per-node kata config via Talos unverified, VM memory invisible to the scheduler without a request, kind-in-kata faults open for e2e jobs |
| C. A scale set per node class | static per class; the job picks via `runs-on` | the node does not decide (the #1582 shape) |
| — admission mutation, LimitRange, VPA | act before a node exists, or one number per namespace/workload | ✗ |
| — the runner self-limits with a child cgroup | needs a writable cgroupfs | ✗ the runner is unprivileged |

## What the spike must settle (option A)

1. **Timing:** the runner takes a job within seconds of starting — the resize must land before
   the job reads `memory.max` (patch at bind, before the container starts; verify it is accepted
   and applied then). Only ever RAISE from the floor (a decrease below usage is refused).
2. **Co-tenancy:** the budget subtracts runners already on the node — else two on nx-01 each
   claim the whole box.
3. **Attribution:** an overrun inside the limit must read OOMKilled on the pod (the alert path),
   not a vanished runner.
4. **Shape:** the controller's home and its one permission (`pods/resize` in `arc-runners`) —
   new machinery + a new permission, so an ADR before it lands.

Acceptance: oracle-fleet's `ci` on nx-01 keeps ~40 workers; on an 8 GB node it sees a ~5 GiB
`memory.max` and passes; a forced overrun reads OOMKilled.
