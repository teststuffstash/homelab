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
([ADR-094](../../../docs/adr.md#adr-094--item-scoped-coordinator-dispatch-the-scan-schedules-the-llm-judges)).
The predicate it implements is the brief's §State machine
([agents/coordinator/README.md](../../../agents/coordinator/README.md)) and the issue machine
[issue-lifecycle-fsm.md](../../../docs/agents/issue-lifecycle-fsm.md) (IL-T*); the scan's header
comment (`coordinator-scan.sh:7-30`) states the actionability predicate in one place and must
track the brief. Terms: [glossary.md](glossary.md), [docs/glossary.md](../../../docs/glossary.md).

## Interface — the machine half

**[`scan-decision.schema.json`](scan-decision.schema.json)** holds the doorbell payload, the unit
grammar, the hold report line and the clause enum.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-WAKE-DOORBELL](#scan-wake-doorbell) | `doorbell`, `env.SCAN_*` | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `doorbell`) |
| [SCAN-WAKE-FASTPATH](#scan-wake-fastpath) | `doorbell.unit`, `unit` | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `unit-fast-path-author`, `unit-fast-path-blocked-on`, `session-belt`) |
| [SCAN-CLAUSE-OWNERSHIP](#scan-clause-ownership) | `clause` | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `clause-coverage`) |
| [SCAN-CLAUSE-QUEUED](#scan-clause-queued) | `unit` (4/5-field) | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `queued-derivation`, `queued-classification`, `review-only-label-combinations`) |
| [SCAN-HOLD-STRUCTURAL](#scan-hold-structural) | `hold.kind = structural` | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `scan-guarded`, `scan-governance`, `classify-touches-repo`) |
| [SCAN-HOLD-TRANSIENT](#scan-hold-transient) | `hold.kind = transient` | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `footprint-entry-split`, `footprint-hold-writerless`, `pr-cap-per-base`, `session-belt`, `live-worker-pod`) |
| [SCAN-CLAUSE-PR](#scan-clause-pr) | `unit` (3-field), `clause` | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `changes-requested`, `merge-conflict`, `unarmed-major`) |
| [SCAN-CLAUSE-DEBOUNCE](#scan-clause-debounce) | (marker — [github-grammar.schema.json](github-grammar.schema.json) `markers.state_fp`) | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `state-fp`, `merge-conflict/debounced`) |
| [SCAN-CLAUSE-PHANTOM](#scan-clause-phantom) | `clause` (`c4c5-redispatch`) | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `c4c5-infeasible`, `c4c5-pod-liveness`, `c4c5-ambig-decidable`, `done-phantom-belt`) |
| [SCAN-CLAUSE-FLEET](#scan-clause-fleet) | — | 🚧 WIP → #3448 (fixture: `fleet-reader-rekey`) · ⚑ gap (2026-11-15, PR #3450 → work #3448): reads the old proxy's `/router-status` |
| [SCAN-CLAUSE-GOAL](#scan-clause-goal) | `unit` (`goal-*`, `merged-closeout`) | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `goal`, `goal-ancestor`, `harvest`) · trigger (b) hold → #3656 — rule-labelled tests in islands/scan/tests/test_checkpoint_b.py over recorded world `goal-checkpoint` ⚖ |
| [SCAN-LANE-WALK](#scan-lane-walk) | `clause` (priority order), `lane` | 🚧 WIP → #3448 — no evidence pipeline yet (fixture: `scan-lane-walk`) |

## The wake

### SCAN-WAKE-DOORBELL

A ring is a doorbell, never a work item: the `/coordinate` payload
(`{repo, unit, loop_ns, stack, source, rail}`, every field optional) only scopes the pass, and
the scan re-applies the full predicate (`coordinate-argo.yaml:10-16`). A ring that carries a
`loop_ns` submits the per-stack scan into that namespace (`--spawn`, `SCAN_STACK`, `LOOP_NS`);
every other ring submits the [switchboard](../../../docs/glossary.md) (`--switchboard`,
ADR-120), which lists no GitHub state and spawns no LLM: a capacity ring fans out to every
graduated stack, a repo-dumb full ring (no `unit`, no `loop_ns`) rings each graduated stack with
its resolved `{stack, loop_ns}` and `unit: -`, a repo-dumb unit ring resolves its repo to its graduated stack and rings it, a
ring already routed per-stack exits, and a stack that is not graduated is reported as served by
no scan path, a warning that fires on every switchboard pass that reaches the fan-out of a full
ring, not on a capacity ring (`coordinator-scan.sh` `switchboard` block, :1456). A starting full scan absorbs
every pending sibling `coordinate*` workflow in its namespace before listing GitHub (the
`doorbell-collapse` block, ADR-106 (5)), so a burst of rings is one pass.

> **External:** MUST — [Argo Events · Sensor trigger parameters § `dataKey` with a static `value` fallback](https://argoproj.github.io/argo-events/tutorials/02-parameterization/) (page and anchor not read this session — verify during implementation) — a missing body key keeps the static default (`repo: all`, `unit: -`) — verify during implementation.

**World:** the `doorbell` family's per-case worlds (Argo workflow lists, `stacks.json` mirrors).

#### What does a ring cause?

| description | world | ring | stacks | expect? |
|---|---|---|---|---|
| collapse | doorbell/collapse | full scan starting with pending sibling `coordinate*` workflows | — | the siblings deleted before the GitHub list |
| switchboard-capacity | doorbell/switchboard-capacity | `source: capacity` | `circles` graduated, `newborn` not | every graduated stack rung (`circles` only, with `source`, `rail`, `loop_ns`), no board scan, no no-scan-path warning |
| ⚖ switchboard-fanout | doorbell/switchboard-fanout | repo-dumb full ring | `circles` graduated, `newborn` not | `circles` (the one graduated stack) rung into its namespace; a no-scan-path warning names `newborn` |
| switchboard-routed | doorbell/switchboard-routed | ring already carrying `loop_ns` | — | exit, nothing rung |
| switchboard-unit | doorbell/switchboard-unit | `unit: changes-requested\|<repo>\|pr-N`, no `loop_ns` | — | the repo's stack rung with that unit |
| fanout | doorbell/fanout | repo-dumb ring from a stack emitter: `{"repo": "all"}`, no `unit`, no `loop_ns`, edge-woken | `circles`, `sleep` graduated | each graduated stack rung with its resolved `{stack, loop_ns}` and `unit: -` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-WAKE-DOORBELL.md"

</details>

### SCAN-WAKE-FASTPATH

A ring whose emitter already knows its unit (a reviewer verdict computes
`changes-requested|<repo>|pr-N` in script code) skips the multi-repo sweep: the scan re-validates
that one item — breaker label, capacity, WIP, the item session belt, a goal-head PR's FU-143
exclusion, a `blocked-on:` marker — and any doubt returns to the full scan, so the compound is
only ever cheaper, never weaker. A `coordinator-<repo>-pr-<n>` session pod already Running for the
item is not doubt but the item's in-flight work: the fast path holds the unit, dispatching nothing
and not falling through to the full scan (FU-146) (`fast_unit_dispatch`, the `unit-fast-path` block, :1497). The
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
An open, un-labelled issue (no `agent*` label) whose native `blockedBy` edges are all closed and
that is older than 24 h is surfaced as its own `🔓 UNBLOCKED-UNLABELED` report line — report-only,
no label is written (the human gate stands: label `agent/queued` to adopt, or close it). An issue
with an open blocker, or with no edges, never gets that line. A bot-authored open issue without
`agent-fix` that no sharper line already names (a `post-launch:` bucket excepted) is reported on the
generic `🌱` awaiting-triage line instead — report-only, the same human gate.

**World:** per-case recorded issue lists.

#### Does a queued issue become a dispatchable unit?

| description | world | issue state | expect? |
|---|---|---|---|
| no-agent-fix | queued-derivation/no-agent-fix | `agent/queued` without `agent-fix` | unit emitted |
| ready | queued-classification/ready | `agent/queued`, every blocker closed | `queued-dispatch` unit |
| held | queued-classification/held | `agent/queued`, a blocker open | `⏳ queued-blocked`, no unit |
| ⚖ blocker-open | unblocked-unlabeled/blocker-open | bot-authored, unlabelled, a blocker open | no `🔓 UNBLOCKED-UNLABELED` line (the generic `🌱` awaiting-triage line only) |
| surfaces | unblocked-unlabeled/surfaces | unlabelled > 24 h, every blocker closed | a `🔓 UNBLOCKED-UNLABELED` line naming the issue and its closed blockers; no label written |

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
`Touches:`) never matches a guarded set. The operator-lane classification is `classify_touches`'
tier for the footprint, the highest across its paths: `machine-merge` (CI gate only),
`codeowner-merge` (a worker may author, a human merges) or `codeowner-author` (only the codeowner
may author — homelab's ❌ set, applied to a homelab slug only; any other repo is classified by its
own `CODEOWNERS`).

**World:** the `scan-guarded` family; homelab rows read the real `scripts/pin-only-lint.sh` from the checkout.

#### Is this footprint dispatchable?

Legend: `CASE_TOUCHES` = the issue's declared footprint; `guarded set` = whether the repo's
declaration of its guarded set can be read; `expect?` = held or dispatched, and the report line.

| description | world | CASE_REPO | CASE_TOUCHES | guarded set | expect? |
|---|---|---|---|---|---|
| homelab-guarded-dir | — | homelab | `agents/coordinator/` | readable | held: `⛔ pin-only GUARDED path`, guarded `agents/coordinator/reflexes-argo.yaml`, `agents/coordinator/sentinel-argo.yaml` |
| homelab-guarded-file | — | homelab | `argocd/platform/openrouter-operator.yaml` | readable | held: `⛔ pin-only GUARDED path`, guarded `argocd/platform/openrouter-operator.yaml` |
| homelab-unguarded-self | — | homelab | `agents/coordinator-scan.sh,agents/replay/` | readable | dispatched |
| homelab-sentinel | — | homelab | `*` | readable | dispatched |
| homelab-set-unreadable | — | homelab | `argocd/resources/loki/` | unreadable | held: `⛔ GUARDED-SET PROBE-FAILED` |
| remote-guarded | agent-runtime-guarded | agent-runtime | `agent-base/devbox.json,agent-base/devbox.lock,agent-base/Dockerfile` | readable | held: `⛔ pin-only GUARDED path`, guarded `agent-base/devbox.json`, `agent-base/devbox.lock` |
| remote-unguarded | oracle-fleet-none | oracle-fleet | `agents/coordinator/` | readable, none declared | dispatched |
| remote-unreadable | — | agent-runtime | `argocd/resources/loki/` | unreadable | held: `⛔ GUARDED-SET PROBE-FAILED` |

#### Who may author this path? (the operator-lane classification)

| description | world | SLUG | FOOTPRINT | expect? |
|---|---|---|---|---|
| homelab-dotagents-author | — | teststuffstash/homelab | `.agents/probe.md` | `codeowner-author` |
| homelab-scripts-unowned | — | teststuffstash/homelab | `scripts/x.sh` | `machine-merge` |
| stack-dotagents-codeowner-merge | oracle-fleet | teststuffstash/oracle-fleet | `.agents/probe.md` | `codeowner-merge` |
| stack-scripts-unowned | oracle-fleet | teststuffstash/oracle-fleet | `scripts/x.sh` | `machine-merge` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-HOLD-STRUCTURAL.md"

</details>

### SCAN-HOLD-TRANSIENT

New work is held, one report line each and no label, while: its footprint overlaps an
in-progress issue's (`fp_conflict_multi`, ADR-097 — Goal-class units exempt, they write no diff)
that still has a writer;
the repo has `REPO_MAX_WIP` (3) live workers; a `coordinator-<repo>-issue-<n>` session pod is
Running for it (FU-146); or the repo carries `REPO_PR_CAP` (3) armed PRs on the **same base** as
the issue's `Base:` (#849 — a master pile never holds a `goal/**` issue; no `Base:` line means the default branch). In-flight recovery
clauses are exempt from all four (`coordinator-scan.sh:2923-2995`). A footprint entry is split
and normalized by `fp_split_entries` / `fp_norm_entry` (`footprint.sh`): an annotation
`path (why)` is the path; an entry with internal whitespace is read whole, never split or
guessed, so a path that is only a prefix of it is not covered. A declared entry that covers a
changed path is a *hold* on that path; a changed path no entry covers is an *escape*. A "live
worker" is a pod (`live_worker_pod_count`, `kube.sh`) whose phase is not `Succeeded`/`Failed`,
whose `agent` container has not terminated, and — when it is `Pending` — that is schedulable or
younger than 30 s.

The hold keeps two writers off one surface, so an in-progress issue with **no live writer** holds
nothing: no live worker pod for it (the `issue-<n>-` pods, counted as above), no
`coordinator-<repo>-issue-<n>` session pod, no open PR strongly linking it (the one strong-link
predicate, any base), untouched past `C4C5_PERSIST_S` (900 s — the window between the dispatch's
label write and its pod never releases), and neither `agent/error` nor `agent/blocked` (a human
owns those). Its footprint leaves the hold set for that pass with one report line naming it; its
own phantom handling ([SCAN-CLAUSE-PHANTOM](#scan-clause-phantom)) is unchanged. ⚖ Releasing is
the judgment: a writer-less label otherwise holds every overlapping sibling for as long as the
label stands (two goal children held a master sibling 3.5 days, 2026-11-16), while a wrong release
costs at worst two concurrent PRs on one path, which the merge path already absorbs. An unreadable
pod, session-pod or open-PR read keeps every footprint. The footprint is not scoped by `Base:`.

**World:** per-row constructed state.

#### Does an in-progress issue's footprint hold an overlapping queued issue?

| description | world | #50 `Touches:` | #60 `Touches:` | #50's writer | #50 updated | #50 labels | probe | expect? |
|---|---|---|---|---|---|---|---|---|
| ⚖ no-writer-releases | footprint-hold-writerless/no-writer | `gateway/specs/endpoints/sessions.md, gateway/src/agent_gateway/` | `gateway/specs/glossary.md, gateway/src/agent_gateway/sessions.py` | none: no pod, no session, no open PR | 2026-11-13 (past the 900 s guard) | `agent/in-progress` | all reads succeed | #60 dispatched; a `footprint NOT holding siblings` line names #50 |
| running-worker-holds | footprint-hold-writerless/running-worker | `gateway/specs/endpoints/sessions.md, gateway/src/agent_gateway/` | `gateway/specs/glossary.md, gateway/src/agent_gateway/sessions.py` | a Running `agent-homelab-issue-50-r2` pod, agent container running | 2026-11-13 | `agent/in-progress` | all reads succeed | #60 held |
| open-pr-holds | footprint-hold-writerless/open-pr | `gateway/specs/endpoints/sessions.md, gateway/src/agent_gateway/` | `gateway/specs/glossary.md, gateway/src/agent_gateway/sessions.py` | an open PR `Implements #50` | 2026-11-13 | `agent/in-progress` | all reads succeed | #60 held |
| session-probe-fail-holds | footprint-hold-writerless/no-writer | `gateway/specs/endpoints/sessions.md, gateway/src/agent_gateway/` | `gateway/specs/glossary.md, gateway/src/agent_gateway/sessions.py` | none | 2026-11-13 | `agent/in-progress` | the session-pod read fails | #60 held |
| recent-holds | footprint-hold-writerless/no-writer | `gateway/specs/endpoints/sessions.md, gateway/src/agent_gateway/` | `gateway/specs/glossary.md, gateway/src/agent_gateway/sessions.py` | none | inside the 900 s guard | `agent/in-progress` | all reads succeed | #60 held |
| ⚖ error-label-holds | footprint-hold-writerless/no-writer | `gateway/specs/endpoints/sessions.md, gateway/src/agent_gateway/` | `gateway/specs/glossary.md, gateway/src/agent_gateway/sessions.py` | none | 2026-11-13 | `agent/in-progress` + `agent/error` | all reads succeed | #60 held |

#### Does the footprint entry hold?

| description | world | declared `Touches:` entry | changed path | expect? |
|---|---|---|---|---|
| plain-entry | — | `mcps/riigiteataja/ingest/delta.py` | `mcps/riigiteataja/ingest/delta.py` | hold |
| annotated-exact | — | `mcps/riigiteataja/ingest/delta.py (log fields only)` | `mcps/riigiteataja/ingest/delta.py` | hold |
| annotated-among-many | — | `chassis/build.py, mcps/riigiteataja/ingest/delta.py (log fields only), tests/test_build.py` | `mcps/riigiteataja/ingest/delta.py` | hold |
| annotated-glob | — | `mcps/riigiteataja/ingest/** (ingest only)` | `mcps/riigiteataja/ingest/delta.py` | hold |
| whitespace-padded | — | `  chassis/build.py  ,  tests/test_build.py  ` | `chassis/build.py` | hold |
| internal-whitespace-prefix | — | `docs/a b.md` | `docs/a` | escape |
| annotated-escape-still-reported | — | `mcps/riigiteataja/ingest/delta.py (log fields only)` | `mcps/riigiteataja/ingest/other.py` | escape |

#### Is a worker live?

| description | world | pod phase / state | expect? |
|---|---|---|---|
| running-agent-alive | — | Running, agent container running | live |
| running-agent-terminated-sidecar-held | — | Running, agent terminated, sidecar holding | not live |
| pending-schedulable | — | Pending, schedulable | live |
| pending-unschedulable | — | Pending, Unschedulable, older than 30 s | not live |
| succeeded-phase | — | Succeeded | not live |

#### Does the per-base PR cap hold?

| description | world | armed PRs | issue `Base:` | expect? |
|---|---|---|---|---|
| pr-cap-per-base (case 1) | pr-cap-per-base | 3 (= cap) on master | `Base: goal/x` | dispatched |
| pr-cap-per-base (case 2) | pr-cap-per-base | 3 (= cap) on master | `Base: master` | held |
| pr-cap-per-base (case 3) | pr-cap-per-base | 3 (= cap) on master | no `Base:` line (the default branch, master) | held |

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
`blocked-on:` marker, and once the PR is reviewable again — a content commit or a body edit newer
than the newest verdict means the worker has answered and re-review is the reviewer's, so no fix
round is spent (the mirror of the reflex's `reviewable_again`). Which reviewer filed the newest
CHANGES_REQUESTED does not matter: the code reviewer and the specs reviewer both re-open their own
verdict on a newer body edit. With nothing newer than the verdict it dispatches a fix round. ⚖ `changes-requested` admits only the worker App's PRs, so an un-armed `major` PR authored by Renovate and carrying CHANGES_REQUESTED is `unarmed-major`'s alone; the lane-walk order ranks clauses only for a PR both admit, which this one is not. `merge-conflict` scopes
to worker-authored PRs, tolerates a null author, and holds when the source issue is blocked; a
Renovate-authored DIRTY PR is rebased by ticking Renovate's own checkbox instead
(`renovate-rebase-tick`). `ci-red` (FU-115) and `arbitrate` (rounds exhausted) are
currency-gated too ([SCAN-CLAUSE-DEBOUNCE](#scan-clause-debounce)); an un-armed PR carrying none of the lane labels is
a report-only orphan, and an un-armed `automerge` or `deps-review` PR older than 24 h is reported as
an un-armed reviewable bump (`unowned-pr-backstop`). ⚖ The `deps-review` and red-`automerge` rows ride the
`unarmed-major` unit, five rides then a human (FU-046, G12b): once five rides are recorded the scan
emits no unit, adds `agent/arbitrate` to the PR and reports one `RIDES EXHAUSTED` line.

**World:** per-case recorded PR lists.

#### Does this PR state emit a unit?

| description | world | PR state | expect? |
|---|---|---|---|
| ⚖ dispatched | changes-requested/dispatched | CHANGES_REQUESTED, nothing newer than the verdict | `changes-requested` unit |
| blocked-held | changes-requested/blocked-held | CHANGES_REQUESTED + `agent/blocked` | held |
| ⚖ reviewable-again-held | changes-requested/reviewable-again-held | CHANGES_REQUESTED, a content commit newer than the verdict | held (re-review pending) |
| body-edit-held | changes-requested/body-edit-held | only the body edited since the verdict | held (re-review pending) |
| ⚖ body-edit-specs-reviewer-held | changes-requested/body-edit-specs-reviewer-held | only the body edited since the verdict, which is the specs reviewer's | held (re-review pending) |
| clause | merge-conflict/clause | worker PR labelled `merge-conflict` | `merge-conflict` unit |
| null-author | merge-conflict/null-author | `merge-conflict`, `author: null` | no crash, scoped out |
| source-issue-blocked | merge-conflict/source-issue-blocked | the PR's issue carries `agent/blocked` | held |
| ⚖ cr-emits | unarmed-major/cr-emits | un-armed `major` authored by Renovate, CHANGES_REQUESTED | `unarmed-major` unit |
| automerge-red-emits | unarmed-major/automerge-red-emits | `automerge` ∧ armed, red at a settled head | `unarmed-major` unit |
| automerge-green-skips | unarmed-major/automerge-green-skips | `automerge` ∧ armed ∧ green | no unit (the reflex's) |
| ⚖ deps-review-rides-exhausted | unarmed-major/deps-review-rides-exhausted | `deps-review`, armed, red; five `unarmed-major` rides already recorded | no unit; `agent/arbitrate` written, a `RIDES EXHAUSTED` report line |
| ⚖ deps-review-unarmed-old | unowned-pr-backstop/deps-review-unarmed-old | labels `dependencies`, `deps-review`; un-armed; open 17 days (> 24 h) | an `un-armed reviewable bump` report line |

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
issue (`goal-checkpoint-b/c-dispatch-marker`). An assembly PR's (head `goal/**`) CHANGES_REQUESTED
wakes `goal-checkpoint` for its Goal instead of a fix round, and is debounced by the same
mechanism under its own clause, `state-fp:assembly-cr:<hash>`: while the marker equals the current
fingerprint the scan reports `DEBOUNCED` and emits no unit.

**World:** per-case recorded PR views and comment timelines.

#### Does an unchanged condition re-emit?

| description | world | state since last marker | expect? |
|---|---|---|---|
| state-fp | state-fp | fingerprint equal | report line, no unit |
| debounced | merge-conflict/debounced | `merge-conflict`, fingerprint equal | report line, no unit |
| debounced | unarmed-major/debounced | fingerprint equal | report line, no unit |
| content-push-rearms | unarmed-major/content-push-rearms | a content commit since the marker | unit |
| ci-red-rerun-wake-dispatch | ci-red-rounds-two-channels/ci-red-rerun-wake-dispatch | same head, a rerun's new `startedAt` | `ci-red` unit |
| assembly-cr-debounced | assembly-cr-debounced | goal assembly PR, CHANGES_REQUESTED, `state-fp:assembly-cr` marker equal | a `DEBOUNCED` report line, no `goal-checkpoint` unit |

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

A **goal child** (`Base: goal/**`) is not reconciled that way, because "no open PR" cannot tell
abandoned work from work merged into the goal branch by a PR that did not cite it (the closing
keyword is inert off the default branch — circles#36). It is held, with one `undecidable` report
line and a `strike-held` class row, unless it is decidable:
(a) its newest `AGENT_STRIKE:`/`AGENT_REPORT:` comment names a `Resumable branch pushed:` branch —
`c4c5-redispatch` resuming that branch (FU-199); a terminal comment without one stays held; or
(b) it has **no terminal comment at all**, no non-terminal worker pod, has been untouched past
`C4C5_PERSIST_S`, and the merged PRs into its own `Base:` (read for that base, up to 100 — a full
page holds) carry none of: a head `fix/issue-<n>-*`, a strong link, a bare `#<n>` mention. It is
then abandoned: `c4c5-redispatch` resuming the origin `fix/issue-<n>-*` branch with the most
commits ahead of the base, or a plain `c4c5-redispatch` when none is ahead. ⚖ The issue's own
head merged into the base holds, with a line naming that PR: it is finished work whose link is
missing, and re-riding it would put a duplicate armed PR on a protected goal branch; every other
merged PR into the base is a sibling's and says nothing about this issue. An unreadable merged-PR,
branch or compare read holds with a `PROBE_FAILED` line.

**World:** `verdict` / `inert` (`c4c5-infeasible`), recorded pod lists. A probe that cannot read
an issue's comments skips the park for that issue: nothing is written, one `PROBE_FAILED` report
line names it, and the issue keeps its ordinary `c4c5-redispatch` unit.

#### What does an abandoned in-progress issue become?

| description | world | condition | expect? |
|---|---|---|---|
| both-issues | c4c5-pod-liveness/both-issues | two in-progress issues, one with a live pod | only the pod-less one redispatched |
| probe-fail | c4c5-pod-liveness/probe-fail | the pod read fails (`STUB_KUBECTL=fail`) | clause skipped |
| parks | verdict | `AGENT_INFEASIBLE: <path>` as a comment's first line | `agent/blocked` + park comment |
| quoted-inert | inert | the same text quoted mid-body | no park |
| probe-fail | inert | `STUB_GH=fail` | no write; a `PROBE_FAILED` report line, #66 keeps its `c4c5-redispatch` unit |
| done-phantom-belt | done-phantom-belt | closed issue, stale `agent/review`, merged PR mentions it, persisted | `agent/done` |

#### Is a goal child with no open PR decidable?

| description | world | terminal comment | #329 updated | merged PRs into the base | origin `fix/issue-329-*` branches | expect? |
|---|---|---|---|---|---|---|
| strike-resumable | c4c5-ambig-decidable/strike-resumable | `AGENT_STRIKE:` + `Resumable branch pushed: fix/issue-329-loop` | 2026-09-01 | not read | not read | `c4c5-redispatch` with work-branch `fix/issue-329-loop` |
| strike-no-resumable | c4c5-ambig-decidable/strike-no-resumable | `AGENT_STRIKE:`, no resumable line | 2026-09-01 | not read | not read | held: `undecidable` line, `strike-held` row |
| ⚖ no-strike | c4c5-ambig-decidable/no-strike | none | 2026-09-01 | none | none | plain `c4c5-redispatch`, no work-branch |
| goal-abandoned-branch | c4c5-ambig-decidable/goal-abandoned-branch | none | 2026-09-01 | #341 (`fix/issue-327-seam`, `Implements #327`), #340 (`fix/issue-328-probe`) | `fix/issue-329-x`, 1 ahead | `c4c5-redispatch` with work-branch `fix/issue-329-x` |
| ⚖ goal-own-head-merged | c4c5-ambig-decidable/goal-own-head-merged | none | 2026-09-01 | #342 from `fix/issue-329-loop`, body not citing #329 | not read | held: a line naming #342, then `undecidable` |
| goal-merged-probe-fail | c4c5-ambig-decidable/no-strike | none | 2026-09-01 | the read fails | not read | held: `PROBE_FAILED` line, then `undecidable` |
| goal-refs-probe-fail | c4c5-ambig-decidable/no-strike | none | 2026-09-01 | none | the read fails | held: `PROBE_FAILED` line, then `undecidable` |
| goal-child-recent | c4c5-ambig-decidable/no-strike | none | inside the 900 s guard | not read | not read | held: `undecidable` line, `strike-held` row |

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
cause, PR or list holds the label (rule #6). On the latch side, a strike whose class is not a
serving class (`unknown`) is attributed to neither a provider nor a model, so it counts as "us";
an unreadable `/router-status` writes no label, files nothing and reports one `⛔` line (rule #6 —
never fail into a write); and the `agent/error` label write rides REST, so a drained GraphQL quota
does not stop it (`gh_label_add`). The `ci-red` clause holds instead of dispatching when
master shows the same failing step on several PRs (`ci-red-fleet-hold`).

⚑ gap: the attribution reads the old proxy's `GET /router-status` (`ROUTER_STATUS_URL`,
`coordinator-scan.sh:88`; `pair_cooldowns`, `serving_classes`, `generations_24h`). In the redrawn
contract the attribution is the gateway's — the strike store behind
[`POST /sessions/{id}/outcome`](../../../gateway/specs/endpoints/sessions.md#gw-sessions-outcome)
— unverified — expected to replace the `/router-status` read one-for-one.

**World:** the `fleet-reader-rekey` strike populations.

#### Whose fault is this strike pattern?

| description | world | ROUTER_STATUS / env | expect? |
|---|---|---|---|
| provider-latch | pair | the pair cooled in the router | provider-latch (no label) |
| model-nomination | across | — | model-nomination (no label) |
| us-case-labels | spread | — | `agent/error` + fleet-fault marker |
| us-case-unknown | unknown | — | `agent/error` + fleet-fault marker, on a non-serving class (`unknown`) |
| router-unreadable | pair | `CURL_RC=1` | no label, no marker; one `⛔` report line |
| us-case-labels-graphql-drained | spread | `STUB_GH_GRAPHQL=drained` | `agent/error` + fleet-fault marker, written over REST |

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
(ADR-122 (4)).

The "child set is complete pre-launch" reason is held while the Goal's assembly pull request is
open and carries the (b) marker for its own number. The assembly pull request of Goal `<g>` is an
open pull request whose head is a `goal/**` branch and whose body carries the line-anchored
trailer `Assembly-for: #<g>`. The marker is a comment on that pull request whose first characters
are `` 🤖 `state-fp:goal-checkpoint-b:<hash>` ``, `<hash>` being the first 12 hex characters of the
SHA-256 of `pr=<number>`. Nothing that happens on the pull request releases the hold: it ends when
the pull request closes or another one replaces it. A marker of another clause on the pull request
(`state-fp:assembly-cr:`) is not the (b) marker and neither holds nor releases (b). The marker is written at dispatch, never at
evaluation, so a Goal that lost its lane is still eligible on the next wake. A `goal-checkpoint` dispatch whose (b) reason is already held — the marker for the open assembly pull request is already on it — issues no marker write, because the marker is written only when (b) is the reason that releases the unit. A refused marker
write is one warning and the dispatch goes on. The marker read follows every page of the pull request's
comments, so a marker past the hundredth comment still holds; there is no comment-count bound. A marker read that fails leaves the reason eligible
with one warning ⚖; this is an exception to "an unreadable probe never becomes a write" below. An open-list read that fails gives no
decision: exit 4, nothing written.

A checkpoint is due for any of three reasons, and the unit names them: the
[findings store](../../../docs/glossary.md) holds at least `GOAL_CHECKPOINT_N` (default 5) undispositioned findings (fewer wake nothing) (total minus
dispositioned, e.g. `findings 5 undispositioned` for 6 total / 1 dispositioned); the child set
is complete pre-launch; a member is undispositioned. The child set is complete pre-launch when the
Goal has no `goal/post-launch` label, at least one member is closed, and no counted member is open.
A counted member is one ruled `adopted`, or one carrying an `agent/*` state label and not ruled
`deferred`. An open member that is unruled and unlabelled is undispositioned: it wakes the checkpoint
and is not counted, so it does not stop the set being complete. When the disposition read fails,
every open member (except the `post-launch:` bucket) is counted. Dispositions are read from the store comment
on the Goal; when that read fails the undispositioned-member wake is held this pass, with one
warning (an unreadable probe never becomes a write). An `adopted` member that is open and carries
no `agent/*` state label is counted but has no waker of its own, so one orphan line names it
(visibility only, nothing written). A queued Goal with no `Base:` line is refused (no decompose
unit) and the refusal names both legal values, `Base: master` and `Base: goal/<branch>`. A merged
PR's issue is closed out by `merged-closeout` (C6, keyed on the pre-merge
lifecycle label, #2808). At dispatch, `merged-closeout`, `goal-checkpoint`, `arbitrate` and
`changes-requested` units carry a **harvest disposition**: the Goal ancestor
(`goal_resolve_ancestor`, `goal-budget.sh`), its `post-launch:` bucket (created and linked by the
scan when missing, its body written through the parser), and `harvest=store|inert` — findings
from an open Goal append to the [findings store](../../../docs/glossary.md), from a dead one land
inert (ADR-102, ADR-106 (3); the `harvest-disposition` block, :7061). ⚖ The goal clauses defer
rather than take the Go rail ([SCAN-DISPATCH-ADMISSION](dispatch.md#scan-dispatch-admission)).

**World:** `open-pre`, `terminal` (`goal`); `homelab-278-tree`, `circles-constructed-parents` (`goal-ancestor`); `circles-29-tree`, `deep-sprout`, `master-inert` (`harvest`); [`goal-checkpoint`](worlds/README.md#recorded-worlds-worldsname--here) (the trigger (b) table).
Every row of the (b) table starts from Goal #3118 with its pre-launch child set complete (a case
input); `A` is the derived open element for pull request #3270, `B` a second derived element with
another number.

#### Does the Goal's tree wake its checkpoint?

| description | world | members | findings store | queued | expect? |
|---|---|---|---|---|---|
| ⚖ bare-members-inert | open-pre | three bare members, none open in the issue list | 6 total, 1 dispositioned | — | `goal-checkpoint` emitted: yes — the same reason as the world without the members (`checkpoint-due` template: `findings 5 undispositioned + child-set complete pre-launch`); the members add nothing to it and none is queued |
| ⚖ undispositioned-wakes | open-pre | the world's tree (two closed members, the `post-launch:` bucket) plus one open member, undispositioned | 6 total, 6 dispositioned | — | `goal-checkpoint` emitted: yes — reasons `child-set complete pre-launch` + `members 1 undispositioned` |
| ⚖ deferred-excluded | open-pre | the world's tree (two closed members, the `post-launch:` bucket) plus one open member, `deferred` | 6 total, 6 dispositioned | — | `goal-checkpoint` emitted: yes — child set complete, no undispositioned-member text |
| ⚖ adopted-open-unlabelled | open-pre | the world's tree (two closed members, the `post-launch:` bucket) plus one open member, `adopted`, no `agent/*` label | 6 total, 6 dispositioned | — | `goal-checkpoint` emitted: no — the member is counted open; one orphan line names it |
| ⚖ dispositions-unreadable | open-pre | the world's tree (two closed members, the `post-launch:` bucket) plus one open member, the disposition read fails | 6 total, 6 dispositioned | — | `goal-checkpoint` emitted: no — the undispositioned wake is held this pass, one warning |
| ⚖ base-required | open-pre | (the world's tree) | 6 total, 1 dispositioned | a second Goal `agent/queued`, no `Base:` line | `goal-decompose` refused: no decompose unit, the refusal names `Base: master` and `Base: goal/<branch>` |

#### Does trigger (b) fire while an assembly pull request is open?

`(b) this wake?` — what `evaluate` prints; the case compares the whole line.
`(b) next wake?` — what `evaluate` prints on the following wake, which reads the world plus the writes this wake issued, with no `fault`.
`since the marker` — what happened on the pull request after the marker was written; `—` where nothing did.

| literal | stdout, one line | stderr | exit |
|---|---|---|---|
| fires-no-pr | `goal-checkpoint-b <g> fires: no open assembly PR` | — | 0 |
| fires-unmarked | `goal-checkpoint-b <g> fires: pr=<n> carries no marker for pr=<n>` | — | 0 |
| fires-unreadable | `goal-checkpoint-b <g> fires: pr=<n> marker read failed` | one warning line | 0 |
| held | `goal-checkpoint-b <g> HELD: pr=<n>` | — | 0 |
| no-decision | nothing | one warning line | 4 |

`marker write?` — the comment writes issued in the wake, `evaluate` and `dispatch` together:

| literal | comment writes issued |
|---|---|
| none | none |
| on A / on B | exactly one, by `dispatch`, on that pull request; its body's first characters are the marker for that pull request's number; answered 201 |
| refused | exactly one, by `dispatch`, answered 403; one warning line; `dispatch` exits 0 |

The table below is generated from [`models/scan-clause-goal-b.yaml`](models/scan-clause-goal-b.yaml); an edit is made in the model.

<!-- generated from specs/models/scan-clause-goal-b.yaml by scripts/render_model.py — edit the model, not this table -->

| description | world | open assembly PR | (b) markers on it | since the marker | fault | lane winner | (b) this wake? | marker write? | (b) next wake? |
|---|---|---|---|---|---|---|---|---|---|
| child-set-complete | goal-checkpoint | none | — | — | — | this Goal | fires-no-pr | none | fires-no-pr |
| lane-lost-stays-eligible ⚖ | goal-checkpoint | A | none | — | — | another unit | fires-unmarked | none | fires-unmarked |
| selected-marks ⚖ | goal-checkpoint | A | none | — | — | this Goal | fires-unmarked | on A | held |
| goal-checkpoint-b-held | goal-checkpoint | A | the marker for A | — | — | this Goal | held | none | held |
| old-fold-markers-not-identity ⚖ | goal-checkpoint | A | the ten recorded on #3270, none of them the marker for A | — | — | this Goal | fires-unmarked | on A | held |
| marker-write-refused ⚖ | goal-checkpoint | A | none | — | the comment write answers 403 | this Goal | fires-unmarked | refused | fires-unmarked |
| marker-read-fails ⚖ | goal-checkpoint | A | the marker for A | — | the read of A's comments fails | another unit | fires-unreadable | none | held |
| pr-list-unreadable ⚖ | goal-checkpoint | A | none | — | the open-list read fails | this Goal | no-decision | none | fires-unmarked |
| goal-checkpoint-b-replaced-releases | goal-checkpoint | B (A is closed: not in the open list) | none on B; the marker for A stays on A | — | — | this Goal | fires-unmarked | on B | held |
| quoted-marker-is-inert ⚖ | goal-checkpoint | A | the marker for A, quoted (each line starts `> `) | — | — | this Goal | fires-unmarked | on A | held |
| head-not-goal-branch-is-no-assembly-pr ⚖ | goal-checkpoint | A, its head branch is not a `goal/**` branch | none | — | — | this Goal | fires-no-pr | none | fires-no-pr |
| goal-checkpoint-b-verdict-held | goal-checkpoint | A | the marker for A | the reviewer bot's APPROVED, newer than the marker | — | another unit | held | none | held |
| goal-checkpoint-b-content-push-held | goal-checkpoint | A | the marker for A | a new head commit id and a second, non-merge commit | — | another unit | held | none | held |
| goal-checkpoint-b-check-flip-held | goal-checkpoint | A | the marker for A | `ci` settled on FAILURE | — | another unit | held | none | held |
| goal-checkpoint-b-inflight-check-held | goal-checkpoint | A | the marker for A | a new head commit id, `ci` with no conclusion yet | — | another unit | held | none | held |
| goal-checkpoint-b-red-rerun-held | goal-checkpoint | A | the marker for A | `ci` re-run after FAILURE, no conclusion yet | — | another unit | held | none | held |
| goal-checkpoint-b-c-armed | goal-checkpoint | A | the marker for A | one open member of the Goal is undispositioned | — | this Goal | held | none | held |
| assembly-cr-wake-b-silent ⚖ | goal-checkpoint | A | the marker for A, and the three `state-fp:assembly-cr:` markers recorded on #3270 | CHANGES_REQUESTED on A | — | this Goal | held | none | held |

<!-- end generated: specs/models/scan-clause-goal-b.yaml -->

`child-set-complete`, `goal-checkpoint-b-held` and `goal-checkpoint-b-replaced-releases` are row
ids of the replay family `goal`, kept verbatim so the replay comparison finds them. The other rows
are new. The marker for A is `92c59fe63be7` (`printf 'pr=3270' | sha256sum | cut -c1-12`); none of
the ten markers recorded on #3270 carries it.

#### Which Goal does a merged PR's finding belong to?

| description | world | lineage | expect? |
|---|---|---|---|
| goal-open-funded | circles-29-tree | open Goal, budget left | the resolved Goal is #29 (open, budget left), `harvest=store` |
| goal-closed | circles-29-tree | closed Goal | the resolved Goal is #29 (closed), `harvest=inert` |
| ⚖ deep-sprout | deep-sprout | several levels below the Goal | the resolved Goal is #29, `harvest=inert` (that Goal is closed) |
| ⚖ master-inert | master-inert | no Goal ancestor | no Goal resolved; the unit carries no `goal=`, `bucket=` or `harvest=` field (master-lane harvest, inert by breaker #1) |
| ⚖ bucket-child | homelab-278-tree | under the `post-launch:` bucket | the resolved Goal is #278, the bucket's parent (one hop above the bucket #295; `walked 1 hop(s) up to goal #278`) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-CLAUSE-GOAL.md"

</details>

## The walk

### SCAN-LANE-WALK

The units are walked **once per (repo, base) lane** ([lane](../../../docs/glossary.md), ADR-125
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
lane siblings' `agent-summary` comments, read-only. An unreadable probe never ages: when the
unit's `agent/queued` label event cannot be read, the scan reports one ``aging: <unit> — no readable `agent/queued` labeled event; ordinary
walk this pass`` line and walks the lane in clause order. The
subscription probe before each spawn after the first is the fleet ceiling: when it fails, the
remaining lanes are not walked this pass (⚑ gap — [SCAN-DISPATCH-ADMISSION](dispatch.md#scan-dispatch-admission)).

**World:** constructed by the bridge per `ROW`.

#### What does a pass dispatch?

| description | world | ROW | lanes | lost dispatches | expect? |
|---|---|---|---|---|---|
| two-lanes | — | two-lanes | `master`: one `changes-requested` (#500); `goal/x`: one queued child (#600) | — | two spawns, `master` lane first (oldest item #500), then `goal/x` (#600) |
| aged | — | aged | one lane (`master`): a `changes-requested` and a `goal-decompose` | 3 | one spawn: `goal-decompose`, before the recovery unit |
| not-yet | — | not-yet | one lane (`master`): a `changes-requested` and a `goal-decompose` | 2 | one spawn: `changes-requested` (ordinary walk) |
| probe-unreadable | — | probe-unreadable | one lane (`master`): a `changes-requested` and a `goal-decompose` | unreadable | one spawn: `changes-requested` (ordinary walk), one report line |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-LANE-WALK.md"

</details>
