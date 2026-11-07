# Glossary — the scan island's ubiquitous language

One definition per term; other pages link here instead of repeating it. Platform-wide terms keep
their homes in [`docs/glossary.md`](../../../../docs/glossary.md) — **lane (merge path)**,
**switchboard**, **findings store**, **Goal**, **theme**, **board** — and the gateway's terms
(**island**, **session**) in [gateway/specs/glossary.md](../../../../gateway/specs/glossary.md).
This file defines only what the scan coins or narrows. None of these names platform functionality
a `docs/glossary.md` row already covers (checked 2026-11-07: no row for unit, clause, hold,
doorbell, phantom, armed track, state fingerprint, aging, item class).

## unit

One dispatchable decision: a line `clause|repo|item[|class[|parent]]` the scan's clauses emit
(`agents/coordinator-scan.sh`, the `fu146-dispatch-loop` block). `item` is `issue-N` or `pr-N`.
Four- and five-field units (`queued-dispatch`, `c4c5-redispatch`) carry the issue's class and,
for a Goal child, the parent Goal; three-field units (the PR clauses) carry neither. A unit is
what crosses into [dispatch.md](dispatch.md); the same string shape is what a doorbell's `unit`
field carries.

## clause

A named predicate over GitHub (+ kube) state that emits units or report lines — `queued-dispatch`,
`c4c5-redispatch`, `arbitrate`, `changes-requested`, `merge-conflict`, `unarmed-major`,
`infra-enrich`, `ci-red`, `merged-closeout`, `goal-checkpoint`, `goal-decompose`, and the
report-only belts. Each is a `>>>REPLAY:<name>>>` sentinel block in the scan, so the replay
harness runs the real code. The clause *priority* is the order in [SCAN-LANE-WALK](scan-decision.md#scan-lane-walk).

## hold

A queued unit the scan does not dispatch this pass, reported with one line. Two kinds:

| kind | examples | what clears it | label written? |
|---|---|---|---|
| structural | pin-only GUARDED path, operator-lane path, GOVERNANCE path | a human re-scopes or splits the issue | no |
| transient | footprint overlap, project WIP ceiling, item session in flight, per-base PR cap, open dependency | the next pass, once the holder moves | no |
| fail-closed | malformed machine block, unreadable guarded/governance set | the author fixes the block / the probe recovers | no |

## doorbell

An at-least-once, missable POST (`/coordinate`, `/update-pr`) whose payload only *scopes* a pass;
the receiver re-derives every fact itself. A false or duplicate ring costs a few `gh` reads,
never an LLM turn (`coordinate-argo.yaml` header). Never a work item.

## armed track

The set of open PRs with auto-merge armed (`autoMergeRequest != null`). Arming — never a label —
decides the owner: armed PRs are the reflexes' (updater, review reflex), un-armed ones the
scan's clauses and the coordinator's ([docs/merge-path-mechanism.md §Reflexes vs judgment](../docs/merge-path-mechanism.md#reflexes-vs-judgment--where-the-coordinator-sits)).

## phantom

A lifecycle label (`agent/in-progress`, `agent/review`, a stale `agent/blocked`/`agent/review` on
a closed issue) that no live pod, open PR or merged PR backs, persisted past `C4C5_PERSIST_S`
(900 s). The scan reconciles a phantom itself ([SCAN-CLAUSE-PHANTOM](scan-decision.md#scan-clause-phantom)).

## state fingerprint

The hash of the PR state a clause's ride will read — `head`, `reviewDecision`, every check's
conclusion, the newest verdict time (`STATE_FP_JQ`; the `ci-red` variant folds each check's
`startedAt`). Written as a `state-fp:<clause>:<hash>` comment at dispatch; a clause whose
condition holds over an unchanged fingerprint emits a report line, not a unit
([SCAN-CLAUSE-DEBOUNCE](scan-decision.md#scan-clause-debounce)).

## aging

The within-lane escape from clause priority: a `goal-decompose` / `queued-dispatch` unit that has
lost `SCAN_AGING_N` (3) consecutive lane dispatches goes to the front of its lane's walk once
([SCAN-LANE-WALK](scan-decision.md#scan-lane-walk)). Derived from the issue's own timeline, no
state written.

## item class

The scan's per-pass classification of each open item for the board — a low-cardinality enum
(`riding`, `phantom`, `strike-held`, `parked-blocked`, `queued-held`, `queued-ready`,
`footprint-held`, `cap-held`, `guarded-path`, `deferred-capacity`, …) with `who ∈ operator |
machine | none` ([SCAN-SIGNAL-CLASS](signals.md#scan-signal-class)).

## merge-ready

An armed PR with nothing but currency and CI between it and auto-merge: `reviewDecision`
APPROVED, or `""` with the reviewer bot's APPROVED newer than the newest non-merge commit (or the
`automerge` label). The updater's leg-1 predicate ([SCAN-UPDATER-PICK](updater.md#scan-updater-pick)).
