---
id: IF-SCAN-DECISION
use-cases: [UC-1]
schema: scan-decision.schema.json
---
# `coordinator-scan.sh` — which items act, which park, which unit each lane dispatches

*Is there anything a coordinator session would act on — and if so, which one unit per lane?* The
scan is woken by a [doorbell](glossary.md#doorbell) (`POST /coordinate`) or its per-stack cron,
re-lists every open issue and PR of the stack's repos, runs each [clause](glossary.md#clause)
over that snapshot, reports every [hold](glossary.md#hold), and hands at most one
[unit](glossary.md#unit) per (repo, base) lane to [dispatch.md](dispatch.md). It never writes a
code change, a branch, an approval or a merge; its writes are the lifecycle reconciliations of
[github-grammar.md](github-grammar.md) and the markers that debounce it
([ADR-094](../../../../docs/adr.md#adr-094--item-scoped-coordinator-dispatch-the-scan-schedules-the-llm-judges)).
The predicate it implements is the brief's §State machine
([agents/coordinator/README.md](../../../coordinator/README.md)) and the issue machine
[issue-lifecycle-fsm.md](../../../../docs/agents/issue-lifecycle-fsm.md) (IL-T*); the scan's header
comment (`coordinator-scan.sh:7-30`) states the actionability predicate in one place and must
track the brief. Terms: [glossary.md](glossary.md), [docs/glossary.md](../../../../docs/glossary.md).

## Interface — the machine half

**[`scan-decision.schema.json`](scan-decision.schema.json)** holds the doorbell payload, the unit
grammar, the hold report line and the clause enum.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-WAKE-DOORBELL](#scan-wake-doorbell) | `doorbell`, `env.SCAN_*` | 🚧 WIP — no evidence pipeline yet (fixture: `doorbell`) |
| [SCAN-WAKE-FASTPATH](#scan-wake-fastpath) | `doorbell.unit`, `unit` | 🚧 WIP — no evidence pipeline yet (fixture: `unit-fast-path-author`, `unit-fast-path-blocked-on`, `session-belt`) |
| [SCAN-CLAUSE-OWNERSHIP](#scan-clause-ownership) | `clause` | 🚧 WIP — no evidence pipeline yet (fixture: `clause-coverage`) |
| [SCAN-CLAUSE-QUEUED](#scan-clause-queued) | `unit` (4/5-field) | 🚧 WIP — no evidence pipeline yet (fixture: `queued-derivation`, `queued-classification`, `review-only-label-combinations`) |
| [SCAN-HOLD-STRUCTURAL](#scan-hold-structural) | `hold.kind = structural` | 🚧 WIP — no evidence pipeline yet (fixture: `scan-guarded`, `scan-governance`, `classify-touches-repo`) |
| [SCAN-HOLD-TRANSIENT](#scan-hold-transient) | `hold.kind = transient` | 🚧 WIP — no evidence pipeline yet (fixture: `footprint-entry-split`, `pr-cap-per-base`, `session-belt`, `live-worker-pod`) |
| [SCAN-CLAUSE-PR](#scan-clause-pr) | `unit` (3-field), `clause` | 🚧 WIP — no evidence pipeline yet (fixture: `changes-requested`, `merge-conflict`, `unarmed-major`) |
| [SCAN-CLAUSE-DEBOUNCE](#scan-clause-debounce) | (marker — [github-grammar.schema.json](github-grammar.schema.json) `markers.state_fp`) | 🚧 WIP — no evidence pipeline yet (fixture: `state-fp`, `merge-conflict/debounced`) |
| [SCAN-CLAUSE-PHANTOM](#scan-clause-phantom) | `clause` (`c4c5-redispatch`) | 🚧 WIP — no evidence pipeline yet (fixture: `c4c5-infeasible`, `c4c5-pod-liveness`, `done-phantom-belt`) |
| [SCAN-CLAUSE-FLEET](#scan-clause-fleet) | — | 🚧 WIP (fixture: `fleet-reader-rekey`) · ⚑ gap: reads the old proxy's `/router-status` |
| [SCAN-CLAUSE-GOAL](#scan-clause-goal) | `unit` (`goal-*`, `merged-closeout`) | 🚧 WIP — no evidence pipeline yet (fixture: `goal`, `goal-ancestor`, `harvest`) |
| [SCAN-LANE-WALK](#scan-lane-walk) | `clause` (priority order), `lane` | 🚧 WIP — no evidence pipeline yet (fixture: `scan-lane-walk`) |

## The wake

### SCAN-WAKE-DOORBELL

A ring is a doorbell, never a work item: the `/coordinate` payload
(`{repo, unit, loop_ns, stack, source, rail}`, every field optional) only scopes the pass, and
the scan re-applies the full predicate (`coordinate-argo.yaml:10-16`). A ring that carries a
`loop_ns` submits the per-stack scan into that namespace (`--spawn`, `SCAN_STACK`, `LOOP_NS`);
every other ring submits the [switchboard](../../../../docs/glossary.md) (`--switchboard`,
ADR-120), which lists no GitHub state and spawns no LLM: a capacity ring fans out to every
graduated stack, a repo-dumb unit ring resolves its repo to its graduated stack and rings it, a
ring already routed per-stack exits, and a stack that is not graduated is reported as served by
no scan path (`coordinator-scan.sh` `switchboard` block, :1456). A starting full scan absorbs
every pending sibling `coordinate*` workflow in its namespace before listing GitHub (the
`doorbell-collapse` block, ADR-106 (5)), so a burst of rings is one pass.

> **External:** MUST — [Argo Events · Sensor trigger parameters § `dataKey` with a static `value` fallback](https://argoproj.github.io/argo-events/tutorials/02-parameterization/) (page and anchor not read this session — verify during implementation) — a missing body key keeps the static default (`repo: all`, `unit: -`) — verify during implementation.

**World:** the `doorbell` family's per-case worlds (Argo workflow lists, `stacks.json` mirrors).

#### What does a ring cause?

| description | world | ring | expect? |
|---|---|---|---|
| collapse | doorbell/collapse | full scan starting with pending sibling `coordinate*` workflows | the siblings deleted before the GitHub list |
| switchboard-capacity | doorbell/switchboard-capacity | `source: capacity` | every graduated stack rung, no board scan |
| switchboard-fanout | doorbell/switchboard-fanout | repo-dumb full ring | the graduated stack rung into its namespace |
| switchboard-routed | doorbell/switchboard-routed | ring already carrying `loop_ns` | exit, nothing rung |
| switchboard-unit | doorbell/switchboard-unit | `unit: changes-requested\|<repo>\|pr-N`, no `loop_ns` | the repo's stack rung with that unit |
| fanout | doorbell/fanout | repo-dumb ring from a stack emitter | the per-stack doorbell rung (FU-144 receiver-side resolution) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-WAKE-DOORBELL.md"

</details>

### SCAN-WAKE-FASTPATH

A ring whose emitter already knows its unit (a reviewer verdict computes
`changes-requested|<repo>|pr-N` in script code) skips the multi-repo sweep: the scan re-validates
that one item — breaker label, capacity, WIP, the item session belt, a goal-head PR's FU-143
exclusion, a `blocked-on:` marker — and any doubt returns to the full scan, so the compound is
only ever cheaper, never weaker (`fast_unit_dispatch`, the `unit-fast-path` block, :1497). The
v1 whitelist is `changes-requested`, plus the goal clauses (`doorbell/goal-fast-path`).

**World:** per-case recorded PR views.

#### When does a unit ring dispatch without the full scan?

| description | world | unit ring state | expect? |
|---|---|---|---|
| unit-fast-path-author | unit-fast-path-author | `changes-requested` on a worker-authored PR | fast-path dispatch |
| unit-fast-path-blocked-on | unit-fast-path-blocked-on | the PR's newest ruling carries `blocked-on:` still unresolved | falls through, no dispatch |
| fu143-fast-path-goal-head | fu143-fast-path-goal-head | the PR's head is `goal/**` (an assembly) | falls through (FU-143 exclusion) |
| fast-path | session-belt/fast-path | a `coordinator-<repo>-pr-<n>` pod is Running | held (item session in flight) |
| fast-path-probe-fail | session-belt/fast-path-probe-fail | the session-pod probe fails | falls through to the full scan |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-WAKE-FASTPATH.md"

</details>

## The clauses

### SCAN-CLAUSE-OWNERSHIP

Every admissible issue state is owned by exactly one issue-level clause, and the human gates and
terminals by none: `queued-dispatch` owns `agent/queued`, `c4c5-redispatch` an abandoned
`agent/in-progress`, `review-phantom` an `agent/review` with no frozen PR, `frozen-open-pr` an
`agent/review` whose PR is armed ∧ bot-APPROVED ∧ green ∧ BEHIND ∧ unmoved; `agent/blocked`,
`agent/error` (the FU-069 breaker) and `agent/done` match none
(the `clause-coverage` block, :7299, runs the real selectors). The PR-level clauses key on PR
state and are not in this table ([SCAN-CLAUSE-PR](#scan-clause-pr)).

**World:** the clause-coverage world ([worlds/README.md](worlds/README.md#family-worlds-fixture-local-worldsname-named-in-rowspsv)).

#### Which clause owns this issue state?

| description | world | issue | state | owners? |
|---|---|---|---|---|
| queued | clause-coverage | #80 | `agent/queued` | `queued-dispatch` |
| queued-goal | clause-coverage | #81 | `agent/queued`, Class goal | `queued-dispatch` |
| in-progress | clause-coverage | #82 | `agent/in-progress`, no live pod | `c4c5-redispatch` |
| review | clause-coverage | #83 | `agent/review` ∧ `agent-fix` | `review-phantom` |
| review-no-fix | clause-coverage | #84 | `agent/review` without `agent-fix` | `review-phantom` |
| review-frozen | clause-coverage | #85 | `agent/review`, PR armed ∧ approved ∧ green ∧ BEHIND ∧ unmoved | `frozen-open-pr` |
| blocked | clause-coverage | #86 | `agent/blocked` | none |
| error | clause-coverage | #87 | `agent/error` | none |
| done | clause-coverage | #88 | `agent/done` | none |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-OWNERSHIP.md"

</details>

### SCAN-CLAUSE-QUEUED

`agent/queued` is the ONE dispatch precondition (ADR-122 (2)); `agent-fix` is never re-tested
(the `queued-derivation` block, :1916 — `agent/queued ∧ ¬direction-change ∧ ¬agent/error`). A
queued issue whose native `blockedBy` edge points at an open issue is reported
`⏳ queued-blocked (waiting #N)` and not dispatched; a closed dependency whose own blocker is
still open holds it as `queued-held-by-ghost` (#833); a repo with no fixer block is reported as
context-only (`coordinator-scan.sh:2786-2794`). The emitted unit carries the class from the
machine block's `Class:` (legacy: the `task/*` label) and, for a Goal child, the parent number.

**World:** per-case recorded issue lists.

#### Does a queued issue become a dispatchable unit?

| description | world | issue state | expect? |
|---|---|---|---|
| no-agent-fix | queued-derivation/no-agent-fix | `agent/queued` without `agent-fix` | unit emitted |
| ready | queued-classification/ready | `agent/queued`, every blocker closed | `queued-dispatch` unit |
| held | queued-classification/held | `agent/queued`, a blocker open | `⏳ queued-blocked`, no unit |
| blocker-open | unblocked-unlabeled/blocker-open | blocker open, not queued | no report |
| surfaces | unblocked-unlabeled/surfaces | every blocker closed, issue unlabelled > 24 h | its own `🔓 UNBLOCKED-UNLABELED` line, no label written |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-QUEUED.md"

</details>

### SCAN-HOLD-STRUCTURAL

A queued issue whose declared `Touches:` footprint lands on a path no worker PR can deliver is
reported every pass and never dispatched, with **no label written** — the overlap may be only
part of the issue's scope, so a human re-scopes or splits it (`coordinator-scan.sh:2796-2890`).
Three sets, tested before every transient hold so the line reads "route to the operator", never
"come back later": the repo's **pin-only GUARDED** set (homelab: the `GUARDED=` line of
`scripts/pin-only-lint.sh`; another repo: the `GUARD_SET:` env of its `ci.yaml`, read through the
API — the set is read, never re-declared, #1855); homelab's **operator-lane** paths
(`classify_touches` → `codeowner-author`); homelab's **GOVERNANCE** set (`scripts/governance-lint.sh`).
An unreadable set HOLDS the issue (rule #6 — never fail into a dispatch). The `*` sentinel (no
`Touches:`) never matches a guarded set.

**World:** the `scan-guarded` family; homelab rows read the real `scripts/pin-only-lint.sh` from the checkout.

#### Is this footprint dispatchable?

Legend: `CASE_TOUCHES` = the issue's declared footprint; `expect?` = the report line the scan emits.

| description | world | CASE_REPO | CASE_TOUCHES | expect? |
|---|---|---|---|---|
| homelab-guarded-dir | — | homelab | `agents/coordinator/` | homelab-guarded-dir |
| homelab-guarded-file | — | homelab | `argocd/platform/openrouter-operator.yaml` | homelab-guarded-file |
| homelab-unguarded-self | — | homelab | `agents/coordinator-scan.sh,agents/replay/` | homelab-unguarded-self |
| homelab-sentinel | — | homelab | `*` | homelab-sentinel |
| homelab-set-unreadable | — | homelab | `argocd/resources/loki/` | homelab-set-unreadable |
| remote-guarded | agent-runtime-guarded | agent-runtime | `agent-base/devbox.json,agent-base/devbox.lock,agent-base/Dockerfile` | remote-guarded |
| remote-unguarded | oracle-fleet-none | oracle-fleet | `agents/coordinator/` | remote-unguarded |
| remote-unreadable | — | agent-runtime | `argocd/resources/loki/` | remote-unreadable |

#### Who may author this path? (the operator-lane classification)

| description | world | SLUG | FOOTPRINT | expect? |
|---|---|---|---|---|
| homelab-dotagents-author | — | teststuffstash/homelab | `.agents/probe.md` | author |
| homelab-scripts-unowned | — | teststuffstash/homelab | `scripts/x.sh` | machine |
| stack-dotagents-codeowner-merge | — | teststuffstash/oracle-fleet | `.agents/probe.md` | merge |
| stack-scripts-unowned | — | teststuffstash/oracle-fleet | `scripts/x.sh` | stack-machine |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-HOLD-STRUCTURAL.md"

</details>

### SCAN-HOLD-TRANSIENT

New work is held, one report line each and no label, while: its footprint overlaps an
in-progress issue's (`fp_conflict_multi`, ADR-097 — Goal-class units exempt, they write no diff);
the repo has `REPO_MAX_WIP` (3) live workers; a `coordinator-<repo>-issue-<n>` session pod is
Running for it (FU-146); or the repo carries `REPO_PR_CAP` (3) armed PRs on the **same base** as
the issue's `Base:` (#849 — a master pile never holds a `goal/**` issue). In-flight recovery
clauses are exempt from all four (`coordinator-scan.sh:2923-2995`). A footprint entry is split
and normalized by `fp_split_entries` / `fp_norm_entry` (`footprint.sh`): an annotation
`path (why)` is the path; an entry with internal whitespace is reported as an escape, never
guessed. "Live worker" is the shared predicate `live-worker-pod` pins.

**World:** per-row constructed state.

#### Does the footprint entry hold?

Legend: `path` = the escape the report names (the row's `params`); the entries themselves are the bridge's constructed `Touches:` values.

| description | world | path | expect? |
|---|---|---|---|
| plain-entry | — | — | hold |
| annotated-exact | — | — | hold |
| annotated-among-many | — | — | hold |
| annotated-glob | — | — | hold |
| whitespace-padded | — | — | hold |
| internal-whitespace-prefix | — | `docs/a` | escape |
| annotated-escape-still-reported | — | `mcps/riigiteataja/ingest/other.py` | escape |

#### Is a worker live?

| description | world | pod phase / state | expect? |
|---|---|---|---|
| running-agent-alive | — | Running, agent container running | running-agent-alive |
| running-agent-terminated-sidecar-held | — | Running, agent terminated, sidecar holding | running-agent-terminated-sidecar-held |
| pending-schedulable | — | Pending, schedulable | pending-schedulable |
| pending-unschedulable | — | Pending, Unschedulable | pending-unschedulable |
| succeeded-phase | — | Succeeded | succeeded-phase |

#### Does the per-base PR cap hold?

| description | world | armed PRs | issue `Base:` | expect? |
|---|---|---|---|---|
| pr-cap-per-base (case 1) | pr-cap-per-base | ≥ cap on master | `goal/x` | dispatched |
| pr-cap-per-base (case 2) | pr-cap-per-base | ≥ cap on master | none (master) | held |
| pr-cap-per-base (case 3) | pr-cap-per-base | ≥ cap on master | absent → default branch | held |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-HOLD-TRANSIENT.md"

</details>

### SCAN-CLAUSE-PR

The PR clauses own what the [armed track](glossary.md#armed-track) cannot progress: a PR is
actionable when it is open ∧ ¬`major/awaiting-human` ∧ (`major` ∨ `merge-conflict` ∨
`CHANGES_REQUESTED` ∨ (`deps-review` ∧ armed ∧ (red ∨ CHANGES_REQUESTED)) ∨ (`automerge` ∧ armed ∧
¬`major` ∧ red at a settled head)) (`coordinator-scan.sh:7-15`). The `major` clause keys on
`autoMergeRequest == null` — an armed major is the reflex's, an un-armed one the coordinator's
(ADR-141). `changes-requested` holds while the PR carries `agent/blocked` or an unresolved
`blocked-on:` marker, and while it is not reviewable again (no content commit or body edit newer
than the newest verdict — the mirror of the reflex's `reviewable_again`). `merge-conflict` scopes
to worker-authored PRs, tolerates a null author, and holds when the source issue is blocked; a
Renovate-authored DIRTY PR is rebased by ticking Renovate's own checkbox instead
(`renovate-rebase-tick`). `ci-red` (FU-115) and `arbitrate` (rounds exhausted) are
currency-gated too ([SCAN-CLAUSE-DEBOUNCE](#scan-clause-debounce)); an un-armed, un-labelled PR is
a report-only orphan (`unowned-pr-backstop`). ⚖ The `deps-review` and red-`automerge` rows ride the
`unarmed-major` unit, five rides then a human (FU-046, G12b).

**World:** per-case recorded PR lists.

#### Does this PR state emit a unit?

| description | world | PR state | expect? |
|---|---|---|---|
| dispatched | changes-requested/dispatched | CHANGES_REQUESTED, new commit after the verdict | `changes-requested` unit |
| blocked-held | changes-requested/blocked-held | CHANGES_REQUESTED + `agent/blocked` | held |
| reviewable-again-held | changes-requested/reviewable-again-held | CHANGES_REQUESTED, nothing new since the verdict | held |
| body-edit-held | changes-requested/body-edit-held | only the body edited since the verdict | held for re-review |
| clause | merge-conflict/clause | worker PR labelled `merge-conflict` | `merge-conflict` unit |
| null-author | merge-conflict/null-author | `merge-conflict`, `author: null` | no crash, scoped out |
| source-issue-blocked | merge-conflict/source-issue-blocked | the PR's issue carries `agent/blocked` | held |
| cr-emits | unarmed-major/cr-emits | un-armed `major`, CHANGES_REQUESTED | `unarmed-major` unit |
| automerge-red-emits | unarmed-major/automerge-red-emits | `automerge` ∧ armed, red at a settled head | `unarmed-major` unit |
| automerge-green-skips | unarmed-major/automerge-green-skips | `automerge` ∧ armed ∧ green | no unit (the reflex's) |
| deps-review-rides-exhausted | unarmed-major/deps-review-rides-exhausted | `deps-review` after five rides | no unit, human cue |
| deps-review-unarmed-old | unowned-pr-backstop/deps-review-unarmed-old | un-armed, un-labelled, old | orphan report |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-PR.md"

</details>

### SCAN-CLAUSE-DEBOUNCE

A condition that holds over unchanged PR state is a report line, not a fresh unit (homelab#198):
immediately **before** spawning an `arbitrate`, `ci-red`, `infra-enrich`, `merge-conflict` or
`unarmed-major` unit the scan writes a `state-fp:<clause>:<hash>` comment
([state fingerprint](glossary.md#state-fingerprint), the `dispatch-marker` block, :6947), and the
clause emits again only once the fingerprint differs. Recording before the spawn is deliberate:
the ride's own push, dismissal or rerun is the state change that re-opens the gate. A refused
marker write WARNs and dispatches anyway — it costs the debounce, never the ride. ⚖ `ci-red`
folds each check's `startedAt` (a rerun re-opens it); `arbitrate` does not (per-check churn
re-armed it as noise, homelab#1011). The goal-checkpoint units carry their own marker on the Goal
issue (`goal-checkpoint-b/c-dispatch-marker`).

**World:** per-case recorded PR views and comment timelines.

#### Does an unchanged condition re-emit?

| description | world | state since last marker | expect? |
|---|---|---|---|
| state-fp | state-fp | fingerprint equal | report line, no unit |
| debounced | merge-conflict/debounced | `merge-conflict`, fingerprint equal | report line, no unit |
| debounced | unarmed-major/debounced | fingerprint equal | report line, no unit |
| content-push-rearms | unarmed-major/content-push-rearms | a content commit since the marker | unit |
| ci-red-rerun-wake-dispatch | ci-red-rounds-two-channels/ci-red-rerun-wake-dispatch | same head, a rerun's new `startedAt` | `ci-red` unit |
| assembly-cr-debounced | assembly-cr-debounced | goal assembly, CHANGES_REQUESTED, fingerprint equal | no `goal-checkpoint` unit |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-DEBOUNCE.md"

</details>

### SCAN-CLAUSE-PHANTOM

A [phantom](glossary.md#phantom) label is reconciled by the scan itself, because the stale label
holds every sibling through the footprint intersection: an `agent/in-progress` issue with no
Running worker pod (the per-issue liveness probe, #2305) and no open PR referencing it (the one
strong-link predicate, #2562) emits `c4c5-redispatch`; once that has persisted past
`C4C5_PERSIST_S` (900 s) with no merged PR mentioning it, the scan puts `agent/queued` back,
removes `agent/in-progress` and comments the audit (homelab#155, IL-T16). The same shape
reconciles `agent/review` (IL-T27) and a closed issue's stale `agent/blocked`/`agent/review` →
`agent/done` (`done-phantom-belt`). A worker's `AGENT_INFEASIBLE:` line — first characters of a
comment, never a quote — parks the issue `agent/blocked` (IL-T26). Any unreadable probe skips the
clause instead of waking.

**World:** `verdict` / `inert` (`c4c5-infeasible`), recorded pod lists.

#### What does an abandoned in-progress issue become?

| description | world | condition | expect? |
|---|---|---|---|
| both-issues | c4c5-pod-liveness/both-issues | two in-progress issues, one with a live pod | only the pod-less one redispatched |
| probe-fail | c4c5-pod-liveness/probe-fail | the pod read fails (`STUB_KUBECTL=fail`) | clause skipped |
| parks | verdict | `AGENT_INFEASIBLE: <path>` as a comment's first line | `agent/blocked` + park comment |
| quoted-inert | inert | the same text quoted mid-body | no park |
| probe-fail | inert | `STUB_GH=fail` | no write |
| done-phantom-belt | done-phantom-belt | closed issue, stale `agent/review`, merged PR mentions it, persisted | `agent/done` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-PHANTOM.md"

</details>

### SCAN-CLAUSE-FLEET

One fleet fault is one latch, not N parks (brief §One fleet fault): the scan counts
`AGENT_STRIKE` `error_class` lines across issues in a 24 h window; the same class on ≥ 2 issues
attributed to neither a provider nor a model is the "us" case and latches `agent/error` with a
fleet-fault marker (IL-T30), while a class attributed to a cell (a provider latched, a model
nominated) writes no label. A latched issue unlatches only when the marker's cause is closed and
the PR's CI is green (an issue with no PR: cause closed and the open-PR list read); an unreadable
cause, PR or list holds the label (rule #6). The `ci-red` clause holds instead of dispatching when
master shows the same failing step on several PRs (`ci-red-fleet-hold`).

⚑ gap: the attribution reads the old proxy's `GET /router-status` (`ROUTER_STATUS_URL`,
`coordinator-scan.sh:88`; `pair_cooldowns`, `serving_classes`, `generations_24h`). In the redrawn
contract the attribution is the gateway's — the strike store behind
[`POST /sessions/{id}/outcome`](../../../../gateway/specs/endpoints/sessions.md#gw-sessions-outcome)
— unverified — expected to replace the `/router-status` read one-for-one.

**World:** the `fleet-reader-rekey` strike populations.

#### Whose fault is this strike pattern?

| description | world | ROUTER_STATUS / env | expect? |
|---|---|---|---|
| provider-latch | pair | the pair cooled in the router | provider-latch (no label) |
| model-nomination | across | — | model-nomination (no label) |
| us-case-labels | spread | — | `agent/error` + fleet-fault marker |
| us-case-unknown | unknown | — | us-case-unknown |
| router-unreadable | pair | `CURL_RC=1` | router-unreadable (no label) |
| us-case-labels-graphql-drained | spread | `STUB_GH_GRAPHQL=drained` | `agent/error` still lands (REST) |

#### When does a fleet latch release?

| description | world | marker · cause · CI | expect? |
|---|---|---|---|
| fleet-fault-unlatch-cause-closed-green | fleet-fault-unlatch-cause-closed-green | marker · closed · green | `agent/error` removed |
| fleet-fault-unlatch-cause-open | fleet-fault-unlatch-cause-open | marker · open · — | held |
| fleet-fault-unlatch-no-marker | fleet-fault-unlatch-no-marker | none | held (human-first) |
| fleet-fault-unlatch-probe-fail | fleet-fault-unlatch-probe-fail | unreadable | held |
| fleet-fault-unlatch-issue-no-pr-list-unreadable | fleet-fault-unlatch-issue-no-pr-list-unreadable | marker · closed · PR list unreadable | held, no write |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-FLEET.md"

</details>

### SCAN-CLAUSE-GOAL

The goal lane: an `agent/queued` Goal emits `goal-decompose` (the session authors its children;
`Base:` is mandatory on a Goal, brief §Goal decompose); an open Goal whose tree holds an
undispositioned member, or whose members are all closed, emits `goal-checkpoint` — bare members
are counted, never queued (ADR-122 (1)), `deferred` members are excluded and `adopted` ones counted
(ADR-122 (4)); a merged PR's issue is closed out by `merged-closeout` (C6, keyed on the pre-merge
lifecycle label, #2808). At dispatch, `merged-closeout`, `goal-checkpoint`, `arbitrate` and
`changes-requested` units carry a **harvest disposition**: the Goal ancestor
(`goal_resolve_ancestor`, `goal-budget.sh`), its `post-launch:` bucket (created and linked by the
scan when missing, its body written through the parser), and `harvest=store|inert` — findings
from an open Goal append to the [findings store](../../../../docs/glossary.md), from a dead one land
inert (ADR-102, ADR-106 (3); the `harvest-disposition` block, :7061). ⚖ The goal clauses defer
rather than take the Go rail ([SCAN-DISPATCH-ADMISSION](dispatch.md#scan-dispatch-admission)).

**World:** `open-pre`, `terminal` (`goal`); `homelab-278-tree`, `circles-constructed-parents` (`goal-ancestor`); `circles-29-tree`, `deep-sprout`, `master-inert` (`harvest`).

#### Does the Goal's tree wake its checkpoint?

| description | world | tree | expect? |
|---|---|---|---|
| bare-members-inert | open-pre | members with no disposition, none queued | checkpoint-due |
| undispositioned-wakes | open-pre | an undispositioned member | undispositioned-wakes |
| deferred-excluded | open-pre | a `deferred` member open | deferred-excluded |
| adopted-open-unlabelled | open-pre | an `adopted` member open, no label | adopted-open-unlabelled |
| dispositions-unreadable | open-pre | the disposition read fails | dispositions-unreadable |
| base-required | open-pre | a Goal with no `Base:` | base-required |

#### Which Goal does a merged PR's finding belong to?

| description | world | lineage | expect? |
|---|---|---|---|
| goal-open-funded | circles-29-tree | open Goal, budget left | goal-open-funded (store) |
| goal-closed | circles-29-tree | closed Goal | goal-closed (inert) |
| deep-sprout | deep-sprout | several levels below the Goal | deep-sprout |
| master-inert | master-inert | no Goal ancestor | master-inert |
| bucket-child | homelab-278-tree | under the `post-launch:` bucket | bucket-child |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-GOAL.md"

</details>

## The walk

### SCAN-LANE-WALK

The units are walked **once per (repo, base) lane** ([lane](../../../../docs/glossary.md), ADR-125
(3)) and at most one unit per lane dispatches per pass. A unit's base is the issue's `Base:` (or
the PR's `baseRefName`), recorded verbatim at emission, defaulting to the repo's default branch,
then `master`; a `Base:` with internal whitespace is prose and folds into the default lane
(`unit_lane_record`, :363). Lanes are ordered by repo emission, then by their oldest item number.
Within a lane the clause priority is fixed — `c4c5-redispatch`, `arbitrate`, `changes-requested`,
`merge-conflict`, `unarmed-major`, `infra-enrich`, `ci-red`, `merged-closeout`, `goal-checkpoint`,
`goal-decompose`, `queued-dispatch` — recovery first, then merge-path exceptions, then closing
loops, and only then new work (`coordinator-scan.sh:6844`). [Aging](glossary.md#aging): a `goal-decompose` /
`queued-dispatch` unit that has lost `SCAN_AGING_N` (3) lane dispatches since its newest
`agent/queued` label event jumps the walk once; the loss count is the `agent-event` markers on the
lane siblings' `agent-summary` comments, read-only. An unreadable probe never ages. The
subscription probe before each spawn after the first is the fleet ceiling: when it fails, the
remaining lanes are not walked this pass (⚑ gap — [SCAN-DISPATCH-ADMISSION](dispatch.md#scan-dispatch-admission)).

**World:** constructed by the bridge per `ROW`.

#### What does a pass dispatch?

| description | world | ROW | expect? |
|---|---|---|---|
| two-lanes | — | two-lanes | two-lanes (one `changes-requested` on master + one queued child on `goal/x`, two spawns) |
| aged | — | aged | aged (`goal-decompose` lost 3 → dispatched before the recovery unit) |
| not-yet | — | not-yet | not-yet (lost 2 → the recovery unit wins) |
| probe-unreadable | — | probe-unreadable | probe-unreadable (one report line, ordinary walk) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-LANE-WALK.md"

</details>
