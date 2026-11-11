# scan specs — the contract, and how it is worked

The spec system for the scan island, in the shape of the gateway island's
([gateway/specs/README.md](../../../../gateway/specs/README.md)): **the reviewer reviews the
result, not the diff.** Every interface has a contract page here with a sibling
`<name>.schema.json`; rows are decision tables of key examples; the replay fixtures are the tests
that would prove them. What the island *is* lives one level up ([../README.md](../README.md));
this directory is only the contract. Written from the point of view of the **redrawn** contracts
([context-and-autonomy.md §Interfaces are redrawn at the cut](../../../../docs/spikes/context-and-autonomy.md#interfaces-are-redrawn-at-the-cut-operator-2026-10-05)):
the item session admits through the gateway's `POST /sessions`, never `/route`; the GitHub
grammar converges on ADR-122 (3)'s one machine block. Where the code has not got there, the row
says so (`⚑ gap`, `🚧 WIP`, "unverified — expected …"). Terms: [glossary.md](glossary.md) and
the platform's [docs/glossary.md](../../../../docs/glossary.md).

## Rules — the pinned process, and what this island adds

The numbered rules 1–11, the test & evidence conventions and the reviewer briefs live ONCE in
allure-behavior-snippets ([ADR-156](../../../../docs/adr.md#adr-156--one-portable-specevidence-process-homed-in-allure-behavior-snippets-one-reviewer-runs-two-briefs-2026-10-16)),
pinned by version: **[RULES.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/RULES.md)**,
**[CONVENTIONS.md @ v0.6.9](https://github.com/teststuffstash/allure-behavior-snippets/blob/v0.6.9/allure_behavior_snippets/process/CONVENTIONS.md)**.
"Rule N" anywhere in this island means rule N there.

What this island adds, by rule:

- **Rule 1 (gate):** reviewer-gated, not codeowner-gated
  ([§Direction 2](../../../../docs/spikes/context-and-autonomy.md#direction-operator-2026-10-05--recorded-not-decided-here)).
  ⚑ gap: no reader today — the claim's `specs` field admits ONE `{root, tests}` pair per repo and
  homelab's names the gateway's (`agents/specs-reviewer-session.sh` `pack_roots`); this root is
  invisible to the specs reviewer until the field becomes a list (§C8 "Not decided here").
- **Rule 3 (IDs):** the prefix is `SCAN-`; areas `WAKE`, `CLAUSE`, `HOLD`, `LANE`, `DISPATCH`,
  `GH`, `UPDATER`, `REFLEX`, `HANDOFF`, `SIGNAL`.
- **Rule 5 (evidence):** ⚑ **none is generated.** The proving tests are the replay fixtures under
  `agents/replay/fixtures/` (the tests-root candidate; P4/P5 of §The plan, #1224). The harness
  asserts an *action stream* per fixture — it emits no Allure story, carries no `rule()` label and
  no `git.commit` stamp. So every requirement whose fixture exists carries the evidence-block
  shell AND `🚧 WIP — no evidence pipeline yet (fixture: <dir>)` in its index Status; a
  requirement with no fixture carries the unverified marker. Verified-ness is derived, never
  declared: today nothing on these pages is verified in rule 5's sense, even where the fixture is
  green in `ci`.
- **Rule 7 (coupling):** each page's sibling schema annotates paths with `x-requirements`. ⚑ gap:
  no spec gate reads them (the gateway's `scripts/spec_gate.py` is scoped to `gateway/`).
- **Rows ⇄ fixtures (CONVENTIONS § The intent column):** a table's `description` cell is the
  proving fixture's row id **verbatim** (table-mode `rows.psv` id, or the actions-mode case dir
  name), `world` is the fixture's world, input columns name the `patch` / `env` condition, and the
  expected column is the fixture's `expect?` template (the row's action stream,
  `expected/<expect>.txt`). That is the header-is-the-parameter-list rule mapped onto the
  harness's own argnames (`id · world · patch · env · expect · params`); the join itself is
  unbuilt.
- **Rule 9 (external facts):** GitHub REST/GraphQL behaviour (update-branch merge commits,
  `reviewDecision`, review `commit_id` re-pointing, label endpoints, the 500k-node cap) and Argo
  Events/Workflows semantics (Sensor parameter defaults, mutex, CronWorkflow labels) are linked
  with `> **External:**` lines at the requirement that rests on them; a fact read only off the wire
  names where it was observed, a fact nobody read says "verify during implementation".
- **Rule 10 (incompleteness):** the `⚑ gap` rows: self-routing in the scan and the reflex
  (`coordinator_rail`, `rail_model`, the goal-lane Go deferral, the reflex's rail tick gate);
  `/router-status` and `/report/latest` reads against the old proxy; the non-platform stacks'
  coordinator still on `resolve-model.sh` → `/route`; the labels-and-body-keys soup not yet one
  block; no detector + revert drill (P4 (c)).
- **Worlds:** every row names its world ([worlds/README.md](worlds/README.md)) — a replay world
  (recorded or constructed GitHub/kubectl answers) plus, where it matters, an env condition.
- **Table shape:** expected columns end in `?`; one question per table; the rows brief's
  checklist is advisory. Mermaid flow overviews are omitted in this spike (no site build).

## Contract page template

```markdown
---
id: IF-<NAME>
use-cases: [UC-1]
schema: <name>.schema.json
---
# <interface> — one-line purpose

## Interface — the machine half
<coupling table: Requirement · governs (schema) · status (🚧 WIP / ⚑ gap)>

## SCAN-<AREA>-<NAME>
<prose: the system, never its tests (rule 11); code cited as file:line or clause sentinel>
**World:** [<world>](worlds/README.md#<world>)
#### <one question per table>
| description | world | <inputs…> | expect? |
<details markdown="1"><summary>Evidence — latest run</summary> --8<-- "SCAN-<AREA>-<NAME>.md" </details>
```

## Index

Start here: **[use-cases/uc-1-queued-issue.md](use-cases/uc-1-queued-issue.md)** (the spine) →
[scan-decision.md](scan-decision.md) (which items act, which park) →
[dispatch.md](dispatch.md) (what goes to launch) →
[github-grammar.md](github-grammar.md) (what is read and written on GitHub) →
[updater.md](updater.md) · [review-reflex.md](review-reflex.md) · [major-handoff.md](major-handoff.md)
(the merge-path reflexes) → [signals.md](signals.md) (wedge and class signals) ·
[glossary.md](glossary.md) · [worlds/](worlds/README.md).

| Requirement | Page | What it pins | Status |
|---|---|---|---|
| [SCAN-WAKE-DOORBELL](scan-decision.md#scan-wake-doorbell) | scan-decision | a ring is a doorbell, never a work item: collapse, per-stack routing, switchboard fan-out | 🚧 WIP — no evidence pipeline yet (fixture: `doorbell`) |
| [SCAN-WAKE-FASTPATH](scan-decision.md#scan-wake-fastpath) | scan-decision | a unit-carrying ring re-validates the one item, any doubt falls through to the full scan | 🚧 WIP — no evidence pipeline yet (fixture: `unit-fast-path-author`, `unit-fast-path-blocked-on`, `fu143-fast-path-goal-head`, `session-belt`) |
| [SCAN-CLAUSE-OWNERSHIP](scan-decision.md#scan-clause-ownership) | scan-decision | every admissible issue state is owned by exactly one clause; the human gates by none | 🚧 WIP — no evidence pipeline yet (fixture: `clause-coverage`) |
| [SCAN-CLAUSE-QUEUED](scan-decision.md#scan-clause-queued) | scan-decision | `agent/queued` is the one dispatch precondition; dependencies gate it | 🚧 WIP — no evidence pipeline yet (fixture: `queued-derivation`, `queued-classification`, `review-only-label-combinations`, `unblocked-unlabeled`, `blocked-by-duplicate`) |
| [SCAN-HOLD-STRUCTURAL](scan-decision.md#scan-hold-structural) | scan-decision | guarded / operator-lane / governance footprints are reported, never dispatched, never labelled | 🚧 WIP — no evidence pipeline yet (fixture: `scan-guarded`, `scan-governance`, `classify-touches-repo`) |
| [SCAN-HOLD-TRANSIENT](scan-decision.md#scan-hold-transient) | scan-decision | footprint, WIP ceiling, item session in flight, per-base PR cap hold new work | 🚧 WIP — no evidence pipeline yet (fixture: `scan-touches-footprint-hold`, `footprint-hold-goal-exempt`, `footprint-conflict-predicate`, `footprint-entry-split`, `pr-cap-per-base`, `session-belt`, `live-worker-pod`) |
| [SCAN-CLAUSE-PR](scan-decision.md#scan-clause-pr) | scan-decision | the PR clauses own the un-armed and the escalated; the armed track is the reflex's | 🚧 WIP — no evidence pipeline yet (fixture: `changes-requested`, `merge-conflict`, `unarmed-major`, `arbitrate`, `ci-red-*`, `unowned-pr-backstop`, `fu124-nudge`) |
| [SCAN-CLAUSE-DEBOUNCE](scan-decision.md#scan-clause-debounce) | scan-decision | a condition over unchanged PR state is a report line, not a fresh unit (the state fingerprint) | 🚧 WIP — no evidence pipeline yet (fixture: `state-fp`, `assembly-cr-debounced`, `merge-conflict/debounced`, `unarmed-major/debounced`) |
| [SCAN-CLAUSE-PHANTOM](scan-decision.md#scan-clause-phantom) | scan-decision | a lifecycle label no live pod or PR backs is reconciled after it persists | 🚧 WIP — no evidence pipeline yet (fixture: `c4c5-*`, `review-phantom-belt`, `done-phantom-belt`, `review-flip-belt`) |
| [SCAN-CLAUSE-FLEET](scan-decision.md#scan-clause-fleet) | scan-decision | one fleet fault is one latch, not N parks; it unlatches when its cause closes green · `⚑ gap`: reads the old proxy's `/router-status` | 🚧 WIP — no evidence pipeline yet (fixture: `fleet-reader-rekey`, `fleet-strike-reader`, `fleet-fault-unlatch-*`, `ci-red-fleet-hold`) |
| [SCAN-CLAUSE-GOAL](scan-decision.md#scan-clause-goal) | scan-decision | the goal lane: decompose, checkpoint, merged-closeout, harvest disposition | 🚧 WIP — no evidence pipeline yet (fixture: `goal`, `goal-ancestor`, `harvest`, `merged-closeout-*`, `fu143-goal-child-closeout`, `assembly-cr-*`, `goal-budget-gate`) |
| [SCAN-LANE-WALK](scan-decision.md#scan-lane-walk) | scan-decision | one unit per (repo, base) lane per pass, fixed clause priority, aging after N lost dispatches | 🚧 WIP — no evidence pipeline yet (fixture: `scan-lane-walk`) |
| [SCAN-DISPATCH-ITEM](dispatch.md#scan-dispatch-item) | dispatch | the item argv the launch side receives — `repo item clause [class parent work-branch goal bucket harvest themes]`, `--wip`, `--detach` · `⚑ gap`: `--model` still sent | 🚧 WIP — no evidence pipeline yet (fixture: `dispatch-phase`, `fu146-resumable-quoted`, `coordinator-pod-manifest`) |
| [SCAN-DISPATCH-ATOMIC](dispatch.md#scan-dispatch-atomic) | dispatch | one coordinator pod per (repo, item); exit 3 = a racing dispatcher won, the walk moves on | 🚧 WIP — no evidence pipeline yet (fixture: `session-atomic-gate`, `fu146-dispatch-loop-scan`, `fu146-dispatch-loop-exit1`) |
| [SCAN-DISPATCH-ADMISSION](dispatch.md#scan-dispatch-admission) | dispatch | the item session's LLM is admitted by the gateway (`POST /sessions`, role coordinator) · `⚑ gap`: platform stack only; scan-side rail probe | 🚧 WIP — no evidence pipeline yet (fixture: `coordinator-gateway-session`, `coordinator-pick-rail`, `coordinator-adopt-model`) |
| [SCAN-DISPATCH-RERUN](dispatch.md#scan-dispatch-rerun) | dispatch | a no-op round after an ARBITRATE directive is re-run by a launch pod, no session | 🚧 WIP — no evidence pipeline yet (fixture: `coordinator-launch-mode`, `arbitrate/no-op-after-directive*`) |
| [SCAN-GH-LABELS](github-grammar.md#scan-gh-labels) | github-grammar | the label vocabulary the island reads and writes; writes ride REST, add before remove | 🚧 WIP — no evidence pipeline yet (fixture: the `*-graphql-drained` rows of `updater`, `reflex-breaker`, `major-handoff`, `c4c5-infeasible`) |
| [SCAN-GH-BODY](github-grammar.md#scan-gh-body) | github-grammar | every body read goes through the one parser; a malformed block holds the issue | 🚧 WIP — no evidence pipeline yet (fixture: `body-block-malformed`, `queued-body-tsv`, `touches-malformed`, `issue-body`, `depends-on-retired-format`) |
| [SCAN-GH-MARKERS](github-grammar.md#scan-gh-markers) | github-grammar | the machine comments the scan writes or reads: `state-fp:`, `agent-event`, `blocked-on`, `AGENT_*` lines | 🚧 WIP — no evidence pipeline yet (fixture: `blocked-on-anchor`, `c4c5-infeasible`, `state-fp`) |
| [SCAN-GH-ONE-BLOCK](github-grammar.md#scan-gh-one-block) | github-grammar | the redrawn grammar: five facts in one machine block | 🚧 WIP → ADR-122 (3) / P3 — not built |
| [SCAN-UPDATER-PICK](updater.md#scan-updater-pick) | updater | leg 1: one merge-ready, armed, BEHIND PR per lane, oldest first, a wedged oldest skipped | 🚧 WIP — no evidence pipeline yet (fixture: `updater`) |
| [SCAN-UPDATER-UNSTRAND](updater.md#scan-updater-unstrand) | updater | leg 2: a CHANGES_REQUESTED ∧ BEHIND PR with new content is brought current | 🚧 WIP — no evidence pipeline yet (fixture: `updater`) |
| [SCAN-UPDATER-CONFLICT](updater.md#scan-updater-conflict) | updater | leg 3: armed ∧ DIRTY carries `merge-conflict`, and only while it is | 🚧 WIP — no evidence pipeline yet (fixture: `updater`) |
| [SCAN-UPDATER-RENOVATE](updater.md#scan-updater-renovate) | updater | Renovate owns its own currency; the merge-ready exception; the hand-back | 🚧 WIP — no evidence pipeline yet (fixture: `updater`, `fu124-nudge`) |
| [SCAN-REFLEX-GATE](review-reflex.md#scan-reflex-gate) | review-reflex | the tick runs only when a rail is clear and only over repos not parked by slo-teeth or opt-out · `⚑ gap`: the rail probe is self-routing | 🚧 WIP — no evidence pipeline yet (fixture: `reflex-tick`, `slo-teeth`, `reviewer-optout`) |
| [SCAN-REFLEX-PICK](review-reflex.md#scan-reflex-pick) | review-reflex | armed ∧ green ∧ ¬DIRTY ∧ reviewable, one per lane, oldest; ARMED PRs only | 🚧 WIP — no evidence pipeline yet (fixture: `review-pick`, `assembly-review-dispatch`) |
| [SCAN-REFLEX-BREAKER](review-reflex.md#scan-reflex-breaker) | review-reflex | an impossible verdict count trips `agent/error`; the round cap escalates to `agent/arbitrate` | 🚧 WIP — no evidence pipeline yet (fixture: `reflex-breaker`) |
| [SCAN-REFLEX-REARM](review-reflex.md#scan-reflex-rearm) | review-reflex | a worker PR that arrived un-armed is armed (C9), never a major or a stacked PR | 🚧 WIP — no evidence pipeline yet (fixture: `c9-rearm`) |
| [SCAN-REFLEX-DECORRELATE](review-reflex.md#scan-reflex-decorrelate) | review-reflex | the reviewer is told the model the fix rode on · `⚑ gap`: read from the old proxy's `/report/latest` | 🚧 WIP — no evidence pipeline yet (fixture: `decorrelate-resolution`) |
| [SCAN-HANDOFF-GATE](major-handoff.md#scan-handoff-gate) | major-handoff | `major/awaiting-human` only with the bot's APPROVED at head carrying the four headings; exit 0/3/4/5 | 🚧 WIP — no evidence pipeline yet (fixture: `major-handoff`) |
| [SCAN-HANDOFF-ARM](major-handoff.md#scan-handoff-arm) | major-handoff | a packaging-only chart major arms instead of parking | 🚧 WIP — no evidence pipeline yet (fixture: `major-handoff`) |
| [SCAN-SIGNAL-PHASE](signals.md#scan-signal-phase) | signals | the scan's phase marker, and the wedge alert's two branches | 🚧 WIP — no evidence pipeline yet (fixture: `scan-phase-marker`, `scan-wedge-alert`) |
| [SCAN-SIGNAL-DISPATCH](signals.md#scan-signal-dispatch) | signals | dispatch latency rows and the edge/cron wake gauges | 🚧 WIP — no evidence pipeline yet (fixture: `dispatch-phase`) |
| [SCAN-SIGNAL-CLASS](signals.md#scan-signal-class) | signals | one `agent_item_class` row per item per pass, its since-timestamp carried | 🚧 WIP — no evidence pipeline yet (fixture: `item-class`, `item-class-batch`) |
| [SCAN-SIGNAL-REVERT](signals.md#scan-signal-revert) | signals | the island's own detector, revert path and drill (P4 (c)) | ⚑ gap — not built |
