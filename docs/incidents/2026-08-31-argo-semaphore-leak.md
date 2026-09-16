# 2026-08-31 — the Argo lock plane wedged: the sync manager corrupted under the #1136 failure storm

**Impact:** the coordinate lane stalled from 11:08Z: every waiter on the
`subscription-capacity/claude` semaphore was told **"Lock status: 5/5"** and the
`coordinator-scan` mutex reported a holder that had already released — **56 `coordinate-*`
workflows Pending** in `agent-coordinator` by 12:10Z, ~1 workflow actually running
fleet-wide. Discovered by the operator on the agent-running dashboard (pending count
climbing) cross-read against the subscription-headroom panel
(`anthropic_subscription_semaphore_running` = 1 vs max 5) — no belt fired.

## Root cause (corrected same-day — the first write blamed GC-without-release)

The controller's **in-memory sync-manager state corrupted at ~11:08Z, at the tail of the
#1136 anonymous-clone failure storm** (10:45–11:10Z, 47+ workflows failing exit-128 in
10–20s each — see TICK-LOG midday entry; fix `13e51ddc`). The acquire/release ledger,
reconstructed from the old controller pod's logs in Loki (tenant `argo`), proves the locks
were NOT leaked by holders:

- 63 semaphore acquisitions in the window, **every one balanced by a logged release**;
- the last acquire ever granted: `coordinate-dn8p7` 11:07:52Z, released 11:08:23Z with
  `availableLocks=5` — the semaphore was **empty**;
- from 11:08:23Z to the restart, **zero further acquisitions**: every `TryAcquire` logged
  "isn't at the front" and stamped waiters with "Lock status: 5/5" against an empty
  semaphore; mutex waiters kept naming the long-released dn8p7 as holder.

So the storm's churn (dozens of near-simultaneous acquire → fail-in-seconds → release →
complete → GC cycles) raced the sync manager into a corrupt queue/counter state **once**,
and nothing reconciles that state at runtime — the wedge was permanent until a restart.
The initial "GC deletes workflows without releasing locks" reading came from dn8p7's
12:08Z GC deletion while waiters named it as holder; the ledger shows its release had
happened at completion an hour earlier — the GC line was a red herring. (Upstream still
carries a long history of sync-state bugs of both shapes: released-then-stuck and
delete-without-release — #6340, #4632, the #12194 regression.) `workflow-controller:v4.0.7`.

## Fix

`rollout restart` of `argo/argo-workflows-workflow-controller` at 12:15:38Z — on boot the
sync manager rebuilds lock state from live workflow statuses only. Acquisitions resumed
immediately (4/5 real holders within a minute), backlog drained 56→0 Pending by ~12:20Z.
The one Running workflow (`iac-sentinel-edge-rdx8d`) rode through untouched.

## Why nothing alerted (the belt audit)

- `AgentQueueStalled` watches `agent/queued` labels × worker pods × open PRs — this wedge
  is **upstream of dispatch** (the coordinate ticks themselves queued), and its
  zero-open-PRs conjunct suppresses it on any normal day regardless.
- `argo-workflows-alerts` holds exactly one alert (controller memory) — nothing reads
  workflow phase counts.
- The discriminating signal WAS in metrics the whole time: the proxy's server-side
  `anthropic_subscription_semaphore_running` (real pods: 1, then 0) while Argo's Pending
  count climbed — "waiters exist + zero real slots consumed + not draining" is exactly the
  corrupt-sync-state shape, and nothing compares them.

## Operational note

A fast-failure storm (mass exit-128, image-pull storms, any burst of workflows completing
in seconds) is now a known **trigger** for this wedge: after any such storm, check that the
semaphore still grants (Pending drains; `anthropic_subscription_semaphore_running` > 0
while waiters exist). If it doesn't, restart the workflow-controller — safe for running
workflows, and the only reconciliation that exists.

## A SECOND cause with the same signature (2026-09-12) — what the belt must discriminate

19:0x–19:2xZ, found by a seat looking for a missing PR review: the lock plane read **5 holders
with zero subscription pods running**, two `review-*` workflows queued behind them (18:05Z,
19:04Z) — the exact picture above. It was **not** a wedge. Both rails were latched
(`/anthropic-limit`: `reason=utilization-7d`, 7d 0.95 vs threshold 0.95, 5h 0.0, header age
~1.9 h, 7d reset 22:00Z), so five `respond-*` workflows were `Running` and each **held its
`subscription-capacity/claude` lock across Argo's retry backoff** while its pods exited 1 on the
designed typed defer (FU-088 latch → FU-113b retry). Holders were real Workflow objects doing
exactly what they should.

Nothing was starved — every claude-tier consumer was latched too, the reviewer included — so this
state is benign. That is the problem for the belt this incident asks for: **"waiters + zero real
slots consumed + not draining" is TRUE of both the corrupt sync state and a fleet-wide capacity
latch**, and only one of them wants a controller restart. The discriminator has to be explicit —
`anthropic_subscription_dispatch_limited == 1` (the existing `SubscriptionDispatchLimited` alert's
expression, `argocd/resources/openrouter-proxy/prometheusrule.yaml`) is the cheap one: latched ⇒
expected, not latched ⇒ wedge. Reading the holding workflows' latest pod phase (absent/Completed
vs never-created) works too and is independent of the proxy.

Operational rule: **never restart the workflow-controller on this shape without checking the
latch first.** Tonight a restart would have "fixed" nothing and re-queued five defers.

Residual (the belt): FU-198.

## Third instance (2026-09-14 12:17Z → 2026-09-16 06:50Z) — a wedged holder, phantom slots, and the belt

Found by the operator on the agent-running dashboard: **137 Pending** fleet-wide. Every waiter read
`subscription-capacity/claude … Lock status: 4/5`; the live holder list had **one** entry —
`fix-debounce-backstop-1789388220`, `Running` since 09-14 12:17Z, its `decide` pod in `Error` with
no `finishedAt` and no retry (the template has none), never finalised — holding one slot AND the
`fix-debounce-decide` mutex, so `fix-debounce-7t4n2` had waited on `decide` since 09-15 00:52Z.
The other three "held" slots existed only in the sync manager. Discriminator read first:
`anthropic_subscription_dispatch_limited` = 0, `anthropic_subscription_semaphore_running` = 1 (the
reviewer) — a wedge, not a latch. **No `respond-*` had completed in 24 h**; four `review-*` had
queued since 09-15 13:25Z. The trigger for the phantom count is not established (no failure storm
was looked for this time).

Recovery, 06:49–06:52Z: deleted the **132 stale queued `respond-*`** (>1 h old — still-firing
alerts re-notify at Alertmanager's `repeat_interval`, and 132 triages draining five at a time
would have held the pool for hours and burnt the 7d budget), deleted the wedged holder,
`rollout restart` of the controller. Ninety seconds later: 144 → 4 Pending, five real `respond-*`
holders, the 30-hour-old `decide` **Succeeded**.

**The belt shipped this time** (FU-198's "Next"): `ArgoLockPlaneWedged` in
`argocd/resources/argo-workflows-alerts/` — `sum(argo_workflows_gauge{phase="Pending"}) >= 10`
while `anthropic_subscription_semaphore_running < anthropic_subscription_semaphore_max` and
`anthropic_subscription_dispatch_limited == 0`, `for: 30m`. Replayed over the 7 days ending
2026-09-16: **fires from 2026-09-15 03:00Z** (27 h before the dashboard read) through the fix;
**quiet on 2026-09-12 20–21Z** (Pending 14–19, latched) and on every other hour. Routed like every
alert — the responder AND `ha-webhook` — so it reaches a human even while the responder is itself
one of the waiters.
