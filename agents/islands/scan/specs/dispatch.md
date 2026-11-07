---
id: IF-SCAN-DISPATCH
use-cases: [UC-1]
schema: dispatch.schema.json
---
# The item dispatch — what the scan hands to the launch side

*Run this one item now, in its own pod, with these launcher-owned parameters.* When the
[lane walk](scan-decision.md#scan-lane-walk) picks a [unit](glossary.md#unit), the scan calls
[`agents/coordinator-session.sh`](../../../coordinator-session.sh) with the item argv below
(`coordinator-scan.sh:7262-7265`, the `fu146-dispatch-loop` block). That script renders ONE pod
per `(repo, item)` — `coordinator-<repo>-<item-key>` — exits at pod-Ready (`--detach`, ADR-106
(5): the scan's mutex spans only the deterministic pass), and the pod runs the coordinator brief
over that one item. The parameters are **launcher-owned** (ADR-094): the scan computes them from
GitHub and kube state, the session never assembles them. The consumer on the LLM side is the
**launch island**: inside the pod, admission is `agents/gateway-admit.sh` → the gateway's
[`POST /sessions`](../../../../gateway/specs/endpoints/sessions.md) — never `/route` in the
redrawn contract. Terms: [glossary.md](glossary.md), [docs/glossary.md](../../../../docs/glossary.md).

## Interface — the machine half

**[`dispatch.schema.json`](dispatch.schema.json)** holds the argv, the `--item` field grammar and
the exit-code contract.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-DISPATCH-ITEM](#scan-dispatch-item) | `argv`, `item` | 🚧 WIP — no evidence pipeline yet (fixture: `dispatch-phase`, `fu146-resumable-quoted`, `coordinator-pod-manifest`) · ⚑ gap: `--model` still sent |
| [SCAN-DISPATCH-ATOMIC](#scan-dispatch-atomic) | `exit` | 🚧 WIP — no evidence pipeline yet (fixture: `session-atomic-gate`, `fu146-dispatch-loop-scan`, `fu146-dispatch-loop-exit1`) |
| [SCAN-DISPATCH-ADMISSION](#scan-dispatch-admission) | `admission` | 🚧 WIP — no evidence pipeline yet (fixture: `coordinator-gateway-session`, `coordinator-pick-rail`) · ⚑ gap: platform stack only; scan-side rail probe |
| [SCAN-DISPATCH-RERUN](#scan-dispatch-rerun) | `launch` | 🚧 WIP — no evidence pipeline yet (fixture: `coordinator-launch-mode`) |

### SCAN-DISPATCH-ITEM

The scan sends `--stack <name> --repos "<repos>" --main-repo <repo> [--loop-ns <stack>-agents]
--wip <N> --detach --item "repo=<r> item=<issue-N|pr-N> clause=<clause> [class=<c>]
[parent=<goal>] [work-branch=<b>] [goal=<g> bucket=<b> harvest=store|inert] [<themes>]"`. Every
`--item` field is a whitespace-free `key=value` token, so the session parses it by splitting on
spaces (`coordinator-session.sh:255-265`; `repo=` and `item=` are required, exit 2 otherwise).
`--wip` is the ADR-097 `AGENT_WIP_LIMIT` for the item's repo — live workers + 1, ceiling-capped,
1 when the probe fails — computed by the scan and carried as pod env. `work-branch` is set only on
a `c4c5-redispatch` whose issue has a resumable branch (a Goal child with an `AGENT_STRIKE`,
IL-T29); its value is one ref, so a branch name with whitespace or a glob is refused rather than
expanded (`fu146-resumable-quoted`). The `goal=… bucket=… harvest=…` triple is the
[harvest disposition](scan-decision.md#scan-clause-goal).

⚑ gap: the scan still sends `--model <coordinatorModel or a Go id>` (`cmodel`, from the stack row
and `rail_model`). In the redrawn contract no caller names a model — the gateway resolves it per
request from the session identity ([GW-MODEL-RESOLVE](../../../../gateway/specs/endpoints/anthropic-messages.md#gw-model-resolve)) —
so `--model` leaves this argv; the only routing input the scan keeps is the clause, which maps to
the gateway's `tier` (`goal-decompose`/`goal-checkpoint` → heavy).

**World:** recorded dispatch loops; the rendered Pod is captured from the kubectl stub's stdin.

#### What reaches the launcher?

| description | world | unit | expect? |
|---|---|---|---|
| scan | dispatch-phase/scan | a `queued-dispatch` unit with class `fix` | one `coordinator-session.sh … --item "repo=… item=issue-N clause=queued-dispatch class=fix"` call + the scan-side phase rows |
| whitespace | — (`RB_SHAPE=whitespace`) | `c4c5-redispatch` with a resumable branch containing whitespace | whitespace (no `work-branch=` token) |
| glob | — (`RB_SHAPE=glob`) | a resumable branch that is a glob | glob (no expansion) |
| coordinator-pod-manifest | coordinator-pod-manifest | platform-stack item session | the Pod as rendered: SA, gateway-token volume, `AGENT_GATEWAY=sessions` env |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-DISPATCH-ITEM.md"

</details>

### SCAN-DISPATCH-ATOMIC

One coordinator pod per `(repo, item)`: before `create`, the launcher reaps a terminal same-key
pod, refuses a live one, and uses `kubectl create` — never `apply`, which would adopt the live pod
— as the atomic test-and-set (`session_atomic_gate`, `coordinator-session.sh:600-616`, `:661`).
Exit **3** means a racing dispatcher won the key: the scan marks the unit tried, prints one
report line and walks to the next unit in the lane; any other non-zero exit flushes the class
rows and ends the scan with that code (`coordinator-scan.sh:7268-7278`). Exit 0 counts the
lane as dispatched.

**World:** constructed dispatch loops (`cases.sh`).

#### What does the scan do with the launcher's exit?

| description | world | exit | expect? |
|---|---|---|---|
| fu146-dispatch-loop-scan | fu146-dispatch-loop-scan | 3 | report line, next unit tried, scan exits 0 when none left |
| fu146-dispatch-loop-exit1 | fu146-dispatch-loop-exit1 | 1 | the scan exits 1 |
| session-atomic-gate | session-atomic-gate | (launcher) a Running same-key pod | `PREFLIGHT REFUSED`, exit 3 |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-DISPATCH-ATOMIC.md"

</details>

### SCAN-DISPATCH-ADMISSION

The item session's LLM is admitted by the gateway: on the platform stack, a headless item session
calls `gw_admit --stack platform --role coordinator --task <pod> --tier <heavy|""> --harness
claude` in-pod (the `coordinator-gateway-session` block, `coordinator-session.sh:374-440`) and
runs claude on the env the gateway returned; a `defer` ends the tick with exit 0 and no doorbell;
a refusal before any request or a fail-closed answer falls back, with one loud line, to the old
proxy path (FU-270 transition fallback). The pod's projected token is pod-bound, so the gateway
reaps the session when the pod ends ([GW-SESSIONS-LIVENESS](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-liveness)).

⚑ gaps (the redrawn contract is not reached):
- every other stack's coordinator resolves its model via `resolve-model.sh --role coordinator` →
  the old proxy's `/route` (`coordinator-session.sh:91-140`);
- the scan itself probes `subscription-latch.sh --pick-rail` before each spawn (`coordinator_rail`),
  ends the pass when both rails are latched, and **defers a `goal-decompose`/`goal-checkpoint` unit
  rather than dispatch it on the Go rail** (`goal_lane_clause`, ⚖ — the class pins a specific
  subscription model). In the redrawn contract this is the gateway's `defer` with
  `retry_after_s`; the scan keeps no rail knowledge.

**World:** constructed gateway answers (`rows.psv`); latch answers stubbed.

#### What does the item session do with the gateway's answer?

| description | world | gateway / latch | expect? |
|---|---|---|---|
| dispatch | — | `dispatch` | dispatch (claude on the returned env) |
| goal-heavy-tier | — | `dispatch`, clause `goal-decompose` | goal-heavy-tier (asks `tier: heavy`) |
| defer | — | `defer` | defer (exit 0, no claude) |
| http-503-fallback | — | 503 | http-503-fallback (old-proxy fallback, one loud line) |
| no-token-fallback | — | no caller token mounted | no-token-fallback |
| oracle-stack | — | stack ≠ platform | oracle-stack (no gateway admission) |
| launch-pod | — | `--launch` pod | launch-pod (no LLM, no admission) |

#### Which rail does the scan pick before a spawn? (⚑ self-routing, leaves with the gateway defer)

| description | world | latch | expect? |
|---|---|---|---|
| anthropic | coordinator-pick-rail/anthropic | subscription clear | dispatch, stack's coordinatorModel |
| go | coordinator-pick-rail/go | Anthropic latched, Go clear | dispatch with the Go model id |
| go-goal-lane | coordinator-pick-rail/go-goal-lane | Anthropic latched, unit `goal-decompose` | deferred-capacity, no dispatch |
| both | coordinator-pick-rail/both | both latched | no dispatch this pass |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-DISPATCH-ADMISSION.md"

</details>

### SCAN-DISPATCH-RERUN

A fix round that completed without a push after an ARBITRATE directive is re-run once by the
launcher itself, never by a coordinator session (IL-T31, homelab#1910): the scan executes every
`noop-rerun` unit outside the lane walk by calling `coordinator-session.sh … --item
"repo=<r> item=<key> clause=noop-rerun" --launch "<repo> --task <key> --round <n> --work-branch
<b> --recipe /work/<repo>/.agents/<class>.yaml"`; the pod runs `agents/agent-session.sh` with that
argv — verbatim the brief's fix-round line — and no LLM, no model, no rail (`noop-rerun-exec`,
`coordinator-scan.sh:6661`). Every `--launch` token must be shell-inert or no pod is created
(exit 2). On success the scan writes a `kind=noop-rerun` event, which spends the directive's one
re-run; a refusal is a report line, never a second unit.

**World:** the launch-mode bridge; the `arbitrate/no-op-after-directive*` worlds for the emit side.

#### When does a no-op round re-run without a session?

| description | world | state | expect? |
|---|---|---|---|
| coordinator-launch-mode | coordinator-launch-mode | `--launch` with an inert argv | the pod runs `agent-session.sh <argv>`, no claude |
| no-op-after-directive-cr-first | arbitrate/no-op-after-directive-cr-first | first no-op after the directive | one `noop-rerun` unit |
| no-op-after-directive-cr-rerun-spent | arbitrate/no-op-after-directive-cr-rerun-spent | the `kind=noop-rerun` event already written | no second launch — the `arbitrate` unit instead |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-DISPATCH-RERUN.md"

</details>
