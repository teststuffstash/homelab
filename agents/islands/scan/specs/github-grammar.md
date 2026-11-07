---
id: IF-SCAN-GITHUB-GRAMMAR
use-cases: [UC-1]
schema: github-grammar.schema.json
---
# The GitHub grammar — what the scan family reads and writes on issues and PRs

*Which labels, body keys and machine comments carry the loop's state, and which of them does this
island write?* GitHub is the loop's only state store: the scan holds state, never a call stack.
Today the state rides 15 labels (8 `agent/*` states + 7 class/verdict labels) and 11 body keys
for five facts — admission, class, budget, one lifecycle state, a Goal verdict
([§Interfaces are redrawn at the cut](../../../../docs/spikes/context-and-autonomy.md#interfaces-are-redrawn-at-the-cut-operator-2026-10-05)).
ADR-122 (3) already rules the target: **one machine block, one parser**. The parser exists
(`agents/issue_body.py`, 13 keys); the labels have not moved into it
([SCAN-GH-ONE-BLOCK](#scan-gh-one-block), unbuilt). The authoritative label table is the brief's
§State machine ([agents/coordinator/README.md](../../../coordinator/README.md)); labels are
provisioned by the AgentStack claim (`labels:` → IssueLabels), never ad hoc. Terms:
[glossary.md](glossary.md), [docs/glossary.md](../../../../docs/glossary.md).

## Interface — the machine half

**[`github-grammar.schema.json`](github-grammar.schema.json)** holds the label vocabulary with
its writers, the machine block keys, and the marker shapes.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-GH-LABELS](#scan-gh-labels) | `labels` | 🚧 WIP — no evidence pipeline yet (fixture: the `*-graphql-drained` rows) |
| [SCAN-GH-BODY](#scan-gh-body) | `machine_block` | 🚧 WIP — no evidence pipeline yet (fixture: `body-block-malformed`, `queued-body-tsv`, `touches-malformed`) |
| [SCAN-GH-MARKERS](#scan-gh-markers) | `markers` | 🚧 WIP — no evidence pipeline yet (fixture: `blocked-on-anchor`, `c4c5-infeasible`, `state-fp`) |
| [SCAN-GH-ONE-BLOCK](#scan-gh-one-block) | `machine_block_redrawn` | 🚧 WIP → ADR-122 (3) / P3 — not built |

### SCAN-GH-LABELS

The island writes exactly these labels, and no other writer may (the rest are the coordinator
session's, the worker launcher's or a human's):

| label | written by (this island) | how |
|---|---|---|
| `agent/queued` | the scan | restored when it reconciles a phantom `agent/in-progress` / `agent/review` |
| `agent/in-progress`, `agent/review` | the scan; `major-handoff.sh` (`agent/in-progress`) | removed on reconcile / on handoff |
| `agent/blocked` | the scan | added on an `AGENT_INFEASIBLE:` park (IL-T26) |
| `agent/done` | the scan | the done-phantom reconcile |
| `agent/error` | the scan (fleet latch), the review reflex (impossible verdict state) | added; the scan removes only its own fleet latch |
| `agent/arbitrate` | the review reflex | added at the round cap |
| `merge-conflict` | the updater | added on armed ∧ DIRTY, removed when no longer |
| `major/awaiting-human` | `major-handoff.sh` ONLY | added after the evidence check |

Every write rides the REST label endpoints through `gh_label_add` / `gh_label_rm`
(`agents/machine-comment.sh:171-190`), never `gh pr|issue edit --add-label` — that is a GraphQL
mutation, and a drained installation GraphQL pool failed it while REST still served (homelab#2476,
FU-290). A relabel adds the new label before removing the old and re-reads the end state (IL-T16;
the brief's "Never leave a relabel half-applied"). A refused write is one loud line and never
becomes a different write. The scan reads `agent-fix` for the board only, never as a dispatch
precondition (ADR-122 (2), ADR-109).

> **External:** MUST — [GitHub REST · Issues › Labels § Add labels to an issue](https://docs.github.com/en/rest/issues/labels#add-labels-to-an-issue) (page and anchor not read this session — verify during implementation) — the endpoint auto-creates a missing label grey; the island creates it first with its colour (`gh label create --force`) — verify during implementation.

**World:** `board` (updater), the reflex-breaker constructed state, `approved` (major-handoff), `verdict` (c4c5-infeasible), `spread` (fleet-reader-rekey) — each with `STUB_GH_GRAPHQL=drained`.

#### Does a label write land while GraphQL is drained?

| description | world | env | expect? |
|---|---|---|---|
| conflict-dirty-graphql-drained | board | `STUB_GH_GRAPHQL=drained` | dirty-label |
| conflict-clear-graphql-drained | board | `STUB_GH_GRAPHQL=drained` | label-clear |
| error-approved-at-head-graphql-drained | — | `IN_V_HEAD=1 IN_V_HEAD_APPROVED=1 STUB_GH_GRAPHQL=drained` | error-trip-drained |
| arbitrate-at-cap-graphql-drained | — | `IN_ROUNDS_TOTAL=12 STUB_GH_GRAPHQL=drained` | arbitrate-trip |
| handoff-graphql-drained | approved | `STUB_GH_GRAPHQL=drained` | handoff |
| parks-graphql-drained | verdict | `STUB_GH_GRAPHQL=drained` | parks |
| us-case-labels-graphql-drained | spread | `STUB_GH_GRAPHQL=drained` | us-case-labels |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-GH-LABELS.md"

</details>

### SCAN-GH-BODY

Every body-grammar read in the scan goes through the one parser, `agents/issue_body.py`
(`ib_get`, `coordinator-scan.sh:100-112`): the machine block between two `---` lines at the top of
the body, flat `key: value`, the 13 ADR-122 keys case-sensitive. The scan reads `Touches:`
(footprint holds), `Base:` (the lane), `Class:` (the unit's class), `Revert:` and `Budget:`
(the latter through `goal-budget.sh`). A key absent from the block falls back to its legacy
line-anchored form and prints `LEGACY-GRAMMAR <key> <ref>` on stderr — the transition's only
progress meter. A block the parser **refuses** (unknown key, indented or bulleted line, duplicate
key, unterminated fence: exit 2) **holds** the issue, reported once with the parser's own message
(rule #6 — every caller treats exit 2 as a hold, never as "absent"). A `Touches:` line written in a
form the parser cannot read (bold, bulleted) is reported as `TOUCHES-MALFORMED` and the issue
treated as exclusive; the scan never guesses a footprint. Bodies the scan *writes* (the
`post-launch:` bucket) are stamped through `issue_body.py set` and must survive their own re-read
before they are posted. A `Depends-on:` line gates nothing (retired 2026-08-07 — native
`blockedBy` edges are the only dependency reader).

**World:** constructed bodies (`CASE_*` env) and recorded issue lists.

#### What does the queued lane read from a body?

| description | world | body | expect? |
|---|---|---|---|
| block-authored | — | `Touches:`/`Base:` inside the machine block | block-authored (the block's values, no LEGACY line) |
| legacy-line | — | `Touches:` as a bare body line, no block | legacy-line (value read, one `LEGACY-GRAMMAR` line) |
| block-malformed | — | a block with an unknown key | block-malformed (held, parser message reported) |
| body-block-malformed | body-block-malformed | a refused block on a queued issue | one hold report, no dispatch |
| touches-malformed | touches-malformed | `**Touches:** …` | `TOUCHES-MALFORMED` report, issue exclusive |
| depends-on-retired-format | depends-on-retired-format | a `Depends-on:` line, no edge | not gated |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-GH-BODY.md"

</details>

### SCAN-GH-MARKERS

The machine comments the island writes or reads; each is anchored at the first characters of a
line, never matched as a substring, so a quote of one is inert:

- writes: `🤖 \`state-fp:<clause>:<hash>\`` on the PR at dispatch ([SCAN-CLAUSE-DEBOUNCE](scan-decision.md#scan-clause-debounce));
  `<!-- agent-event kind=<k> ts=<iso> -->` lines appended to the item's single
  `<!-- agent-summary -->` comment (`mc_event`, `machine-comment.sh:86` — `arbitrate`,
  `noop-rerun`, the phantom audits); `AGENT_ERROR:` on a reflex breaker trip;
- reads: `blocked-on: <human|issue=N|pr=N>` on the newest ruling (brief §Blocked-on marker — the
  `changes-requested`, `arbitrate` and `ci-red` clauses hold while it is unresolved);
  `AGENT_INFEASIBLE: <path>` (park), `AGENT_STRIKE` with an `error_class` (the fleet reader),
  `ci-cause:` (the ci-red ruling's cause line).

⚖ ADR-103 (2) rules machine residue out of timelines; the comment markers are the residue — the
redrawn contract is one typed event per ride outcome ([§Interfaces](../../../../docs/spikes/context-and-autonomy.md#interfaces-are-redrawn-at-the-cut-operator-2026-10-05)
"Observability"), unverified — expected to replace `agent-event` and `ci-cause:` first.

**World:** `line1` (`blocked-on-anchor`), `verdict`/`inert` (`c4c5-infeasible`).

#### Where does a `blocked-on:` marker count?

| description | world | marker position | expect? |
|---|---|---|---|
| line1 | line1 | the ruling comment's first line | held |
| mid | line1 | a later line of the comment | held |
| absent | line1 | none | ordinary |
| quoted | line1 | inside a quote | ordinary |
| absent-graphql-drained | line1 | none, `STUB_GH_GRAPHQL=drained` | ordinary |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-GH-MARKERS.md"

</details>

### SCAN-GH-ONE-BLOCK

The redrawn grammar: the five facts the labels and keys carry today live in **one machine block**,
read by the one parser and written by the one writer (ADR-122 (3); P3 of
[§The plan](../../../../docs/spikes/context-and-autonomy.md#the-plan-ordered-each-step-one-session--one-pr--a-settle-number)):
admission (`agent/queued` today), class (`Class:` — done), budget (`Budget:` — done), the one
lifecycle state (`agent/in-progress|review|blocked|done|error|arbitrate` today), and a Goal
verdict. `grep -l 'Touches:'` over `agents/ scripts/ .agents/` returning the library and the
authoring writer only is P3's settle number. Unbuilt: the state and admission facts are labels;
the legacy line-anchored reads are still served; the PR side (`merge-conflict`, `major`,
`automerge`, `deps-review`) has no block at all. ⚖ Whether a lifecycle state belongs in an
editable body or stays a label (GitHub's label events give the [aging](glossary.md#aging) read a
free timestamp) is open — the design session's call, not this page's.

_Evidence: none yet — unverified._
