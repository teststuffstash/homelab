# Glossary — the scan island's ubiquitous language

One definition per term; other pages link here instead of repeating it. Platform-wide terms keep
their homes in [`docs/glossary.md`](../../../docs/glossary.md) — **lane (merge path)**,
**switchboard**, **findings store**, **Goal**, **theme**, **board** — and the gateway's terms
(**island**, **session**) in [gateway/specs/glossary.md](../../../gateway/specs/glossary.md).
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
scan's clauses and the coordinator's ([docs/agents/merge-path.md §Reflexes vs judgment](../../../docs/agents/merge-path.md#reflexes-vs-judgment--where-the-coordinator-sits)).

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

## merge commit

A commit with two or more parents. Its message decides nothing: a two-parent commit titled by hand (`Merge master into goal/x`) is a merge commit, and a one-parent commit whose headline reads `Merge branch 'master' into <head>` is content. A merge commit is not new content — it never moves a pull request's newest non-merge commit. The parents are read from the pull-commits read, `gh api repos/<slug>/pulls/<n>/commits?per_page=100` (each element's `parents`), joined to the commits of the PR view by `sha` = `oid`. ⚖ A view commit with no element in that answer leaves the commits unreadable (the updater holds the PR; the handoff exits 4). The read is one page of at most 100 elements and is never followed, so a view commit listed past that page has no element and holds. The alternative, following the pages, changes the answer's shape for a case no recorded pull request shows.

> **External:** MUST — [GitHub REST · Pulls § List commits on a pull request](https://docs.github.com/en/rest/pulls/pulls#list-commits-on-a-pull-request) (operation `pulls/list-commits`) — each element carries `sha` and `parents[]`; `per_page` is at most 100, and the list holds at most 250 commits of a pull request. Read off the wire, 2026-11-23: of the 14 commits of `teststuffstash/homelab` PR #3615, six carry two `parents`, three of them titled by hand (`cd6c61d0` `Merge master into goal/3300-wire-record (#3615)`, `cbd233de`, `fc9f8a9a`); recorded as world `pr-merges`.

## merge-ready

An armed PR with nothing but currency and CI between it and auto-merge: `reviewDecision`
APPROVED, or `""` with the reviewer bot's APPROVED newer than the [newest non-merge commit](#merge-commit) (or the
`automerge` label). The updater's leg-1 predicate ([SCAN-UPDATER-PICK](updater.md#scan-updater-pick)); leg 1 also updates a pull request that is not merge-ready when its red is an [inherited red](#inherited-red).
For a Renovate PR that is untouched or updater-merged ([SCAN-UPDATER-RENOVATE](updater.md#scan-updater-renovate)) the rollup must also be green, and a CANCELLED check outlived by a same-named sibling is not red.

## inherited red

A pull request's red that is its base's, not its own: the newest `ci` check run at its head failed, and it started before the newest `ci` check run at its base's head, which succeeded. An update merges the healed base in and the next run decides. The predicate and its reads: [SCAN-UPDATER-PICK](updater.md#scan-updater-pick).
