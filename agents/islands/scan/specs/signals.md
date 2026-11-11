---
id: IF-SCAN-SIGNALS
use-cases: [UC-1]
schema: signals.schema.json
---
# The scan's signals — phase, dispatch latency, item class (pushgateway)

*Is the scan alive and moving, how long did a dispatch take to reach the launcher, and what does
the board look like this pass?* The scan pushes three metric families to the pushgateway; the
alert rules and `board.sh --machine` are their consumers (they live in
`argocd/resources/pushgateway/prometheusrule.yaml`, not in this island). Every push is a report,
never a gate: an unreachable pushgateway is one stderr line and dispatch proceeds; a jail or
manual run with no pod identity pushes nothing. Terms: [glossary.md](glossary.md),
[docs/glossary.md](../../../../docs/glossary.md).

## Interface — the machine half

**[`signals.schema.json`](signals.schema.json)** holds the families, their grouping keys and
labels.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-SIGNAL-PHASE](#scan-signal-phase) | `agent_scan_phase` | 🚧 WIP — no evidence pipeline yet (fixture: `scan-phase-marker`, `scan-wedge-alert`) |
| [SCAN-SIGNAL-DISPATCH](#scan-signal-dispatch) | `agent_dispatch_phase` | 🚧 WIP — no evidence pipeline yet (fixture: `dispatch-phase`) |
| [SCAN-SIGNAL-CLASS](#scan-signal-class) | `agent_board` | 🚧 WIP — no evidence pipeline yet (fixture: `item-class`, `item-class-batch`) |
| [SCAN-SIGNAL-REVERT](#scan-signal-revert) | — | ⚑ gap — not built (P4 (c)) |

### SCAN-SIGNAL-PHASE

At every phase transition the scan pushes `agent_scan_phase_start_timestamp{pod}` (now) and
`agent_scan_in_deterministic{pod}` (1 = the deterministic pass, 0 = blocked on a dispatched
session) to group `job=agent_scan_phase, namespace=<ns>` (`scan_phase`, `coordinator-scan.sh:309`).
Nothing is pushed before the first transition, by design: until then pod lifetime IS the phase
duration, so `AgentCoordinateScanWedged`'s no-marker branch measures it exactly — including a scan
wedged before the script runs (homelab#103: stuck in `git clone`, holding the mutex). The alert
fires when a `coordinate-*`/`switchboard-*` pod has run > 900 s with no marker, or has been in the
deterministic phase > 900 s by its marker; a marker older than the pushgateway's restart is not
trusted. The single-writer assumption is the `coordinator-scan` mutex; without it two scans in one
namespace would trade markers and fall back to the pod-lifetime branch (a false positive, never a
missed wedge).

**World:** stubbed pushgateway + promtool fixtures.

#### What does the wedge alert see?

| description | world | state | expect? |
|---|---|---|---|
| scan-phase-marker | scan-phase-marker | into a dispatch, back to the deterministic pass, an unknown phase, no gateway, a refused push | two pushes (`in_deterministic` 0, then 1); the degenerate calls push nothing and never fail |
| scan-wedge-alert | scan-wedge-alert | the promtool series for both branches | the alert fires on both, not on a fresh pod |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-SIGNAL-PHASE.md"

</details>

### SCAN-SIGNAL-DISPATCH

At each dispatch the scan publishes the coordinator-owned phases above the launcher (FU-160):
`agent_dispatch_phase_seconds{phase="ring-to-scan"}` — from the Workflow's `creationTimestamp` to
the script's start, emitted for **edge** wakes only (a row exists ⇔ edge-woken) — and
`{phase="scan"}`, from the script's start (or the previous dispatch) to this one; grouping
`job=agent_dispatch_phase/project/<main-repo>/role/coordinator-scan[/base/<lane base>]`. It also
stamps `agent_dispatch_edge_woken_timestamp` or `agent_dispatch_cron_woken_timestamp` (two
metric names, so an edge dispatch never deletes the record of the last cron one) and a per-clause
`agent_dispatch_wake_clause_timestamp` (`dispatch_phase`, `coordinator-scan.sh:1152`). The wake
source is read off the scan's own Workflow object: a cron-submitted one carries
`workflows.argoproj.io/cron-workflow`. `AgentDispatchCronWoken` fires on ≥ 2 cron-woken dispatches
on one (project, base) lane in 24 h — a dead doorbell edge, with an id.

> **External:** MUST — [Argo Workflows · CronWorkflow](https://argo-workflows.readthedocs.io/en/latest/cron-workflows/) (page and anchor not read this session — verify during implementation) — the controller labels a submitted Workflow `workflows.argoproj.io/cron-workflow`; observed on the live `coordinate-perstack-*` workflows (the spike specimen named in the block).

**World:** recorded Workflow objects.

#### Which dispatch rows does a wake publish?

| description | world | wake | expect? |
|---|---|---|---|
| scan | dispatch-phase/scan | edge (Sensor-submitted Workflow) | `ring-to-scan` + `scan` rows, `edge_woken` stamp |
| session | dispatch-phase/session | the launcher half | the session-side rows (`coordinator-session.sh`) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-SIGNAL-DISPATCH.md"

</details>

### SCAN-SIGNAL-CLASS

Each pass classifies every open item it sees into one [item class](glossary.md#item-class) and
pushes, once after the stacks loop, `agent_item_class{repo,item,class,who,base} 1` and
`agent_item_class_since_timestamp_seconds{…}` to group `job=agent_board, namespace=<ns>`
(`item_class_push` / `item_class_flush`, `coordinator-scan.sh:458-570`). The push replaces the
group, so a closed item drops off at the next pass. The since-timestamp is carried from the
group's previous state when the FULL label set — `base` included — is unchanged, so an item that
changes lane restarts its clock. Flushing once per pass (not per stack) is what keeps every
stack's rows: the pushgateway replaces per metric name within a group.

**World:** stubbed pushgateway.

#### What reaches the board?

| description | world | pass | expect? |
|---|---|---|---|
| item-class | item-class | items classified in one pass | one batched push of `agent_item_class` + since rows to `job=agent_board` |
| item-class-batch | item-class-batch | several pushes accumulated, an unchanged (item, class) from the previous pass | one POST; the unchanged pair keeps its earlier since-timestamp |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-SIGNAL-CLASS.md"

</details>

### SCAN-SIGNAL-REVERT

The island's own production guard (P4 (c) of
[§The plan](../../../../docs/spikes/context-and-autonomy.md#the-plan-ordered-each-step-one-session--one-pr--a-settle-number)):
a detector built from these signals that tells a bad scan change from a quiet board, the revert
path (a revert PR — the pods clone master), and a drill that drives the chain end to end. Not
built. The nearest pieces are `AgentCoordinateScanWedged` (liveness, not output) and
`AgentDispatchCronWoken` (dead edges); neither detects a scan that runs on time and dispatches the
wrong unit. ⚖ A candidate detector is a sustained `agent_item_class{class="queued-ready"}` count by
lane with zero dispatches — unverified.

_Evidence: none yet — unverified._
