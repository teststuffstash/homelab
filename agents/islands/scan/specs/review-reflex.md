---
id: IF-SCAN-REVIEW-REFLEX
use-cases: [UC-1]
schema: review-reflex.schema.json
---
# `review-reflex.sh` — dispatch one reviewer per lane for an armed, green, reviewable PR

*Which armed PR in this lane is waiting for a review verdict?* The review reflex is the
coordinator subsystem's mechanical transition "PR green + armed + unreviewed → dispatch a
reviewer", extracted so it never costs an LLM turn. The fast path is the github-exporter's POST to
the `review` Sensor; this script is the level-triggered `*/15` CronWorkflow **backstop**
(`reflexes-argo.yaml`). Each tick it reaps finished reviewer pods, picks at most one PR per
(repo, base) lane, and runs `reviewer-session.sh <repo> <pr>` for each — the consumer is the
**review island** — capped at `REVIEW_CONCURRENCY` (2) concurrent reviewer pods globally. It
selects **armed PRs only**: arming is the boundary between the reflexes and the coordinator's
un-armed lanes ([armed track](glossary.md#armed-track)). It never merges and never decides; what
it cannot progress it labels for the coordinator. A graduated stack is reviewed by its own
per-stack instance (`SCAN_STACK`, `--loop-ns`); the global one skips it. Design narrative:
[../docs/merge-path-mechanism.md](../docs/merge-path-mechanism.md#why-update-before-review-and-why-reviews-serialize-per-repo-base-lane);
MP-T03/MP-T04 in [merge-path-fsm.md](../../../../docs/agents/merge-path-fsm.md). Terms:
[glossary.md](glossary.md), [docs/glossary.md](../../../../docs/glossary.md).

## Interface — the machine half

**[`review-reflex.schema.json`](review-reflex.schema.json)** holds the pick line, the dispatch
argv and the breaker actions.

| Requirement | Governs (schema) | Status |
|---|---|---|
| [SCAN-REFLEX-GATE](#scan-reflex-gate) | `tick` | 🚧 WIP — no evidence pipeline yet (fixture: `reflex-tick`, `slo-teeth`, `reviewer-optout`) · ⚑ gap: rail probe is self-routing |
| [SCAN-REFLEX-PICK](#scan-reflex-pick) | `pick`, `dispatch` | 🚧 WIP — no evidence pipeline yet (fixture: `review-pick`, `assembly-review-dispatch`) |
| [SCAN-REFLEX-BREAKER](#scan-reflex-breaker) | `breaker` | 🚧 WIP — no evidence pipeline yet (fixture: `reflex-breaker`) |
| [SCAN-REFLEX-REARM](#scan-reflex-rearm) | `rearm` | 🚧 WIP — no evidence pipeline yet (fixture: `c9-rearm`) |
| [SCAN-REFLEX-DECORRELATE](#scan-reflex-decorrelate) | `dispatch.decorrelate_from` | 🚧 WIP (fixture: `decorrelate-resolution`) · ⚑ gap: reads the old proxy's `/report/latest` |

### SCAN-REFLEX-GATE

A tick runs only over repos that may be reviewed now: a stack whose error budget is burnt is
parked (`slo-teeth.sh --filter`, fail-open — a dead Prometheus never freezes every merge lane),
a stack whose claim says `reviewer.enabled: false` is dropped (`reviewer-optout.sh`), and when
both subscription rails are latched the whole tick is skipped (`review-reflex.sh:102-114`).

⚑ gap: the rail check is `subscription-latch.sh --pick-rail` — self-routing. Each dispatched
reviewer session already admits through the gateway where it can (the review island's concern);
in the redrawn contract the reflex asks nothing about rails and a reviewer the gateway defers is
the review island's `defer`.

**World:** stubbed latch answers.

#### Does the tick proceed?

| description | world | latch | expect? |
|---|---|---|---|
| proceed | reflex-tick/proceed | a rail clear | proceed |
| skip | reflex-tick/skip | both rails latched | skip (exit 0, nothing listed) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-REFLEX-GATE.md"

</details>

### SCAN-REFLEX-PICK

Per lane (`group_by(.baseRefName)`), the oldest PR (`sort_by(.createdAt)`) that is not a draft,
not `automerge` (the mechanical class — no review), not `agent/error`, not `agent/arbitrate`,
**armed**, not DIRTY, **green**, not APPROVED, and either not CHANGES_REQUESTED or reviewable again
(a non-merge commit or a body edit newer than the newest verdict), with no reviewer-bot APPROVED
newer than its newest non-merge commit (`review-pick` block, `review-reflex.sh:271-398`). Green
means every check context's newest non-CANCELLED conclusion is SUCCESS/NEUTRAL/SKIPPED and every
required context of the default branch's ruleset is present (an unreadable ruleset is treated as
none required, fail-open). A merge commit — any of GitHub's three default merge-message shapes —
is not new content. BEHIND is admitted for a first review (ADR-125: an update-branch merge does
not dismiss a review); DIRTY is not. A PR that already has a live `app=agent-reviewer` pod is
skipped. An assembly PR (head `goal/**`) is reviewed with the goal rubric
(`--rubric .agents/review-goal.md`) and, like every review, names no model.

> **External:** MUST — [GitHub · About protected branches § Dismiss stale pull request approvals](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches#dismiss-stale-pull-request-approvals-when-new-commits-are-pushed) (page and anchor not read this session — verify during implementation) — read off the wire: an update-branch merge re-points the review's `commit_id` and the approval survives (PR#1386, 4 updater merges, 2026-09-05).

**World:** per-case recorded PR lists (two lanes: master and `goal/x`).

#### Which PR does the lane review next?

| description | world | lane state | expect? |
|---|---|---|---|
| two-lanes-two-picks | review-pick/two-lanes-two-picks | one reviewable PR on master, one on `goal/x` | two picks |
| same-lane-oldest | review-pick/same-lane-oldest | two reviewable PRs on master | one pick, the older (`#101`) |
| behind-first-review-admitted | review-pick/behind-first-review-admitted | BEHIND, green, never reviewed | picked |
| behind-cr-no-content-held | review-pick/behind-cr-no-content-held | CHANGES_REQUESTED, nothing new | held |
| behind-cr-remote-merge-held | review-pick/behind-cr-remote-merge-held | CHANGES_REQUESTED, only a merge commit since | held |
| required-context-absent-held | review-pick/required-context-absent-held | a required context missing from the rollup | held |
| only-cancelled-held | review-pick/only-cancelled-held | a context whose only run is CANCELLED | held |
| superseded-cancel-admitted | review-pick/superseded-cancel-admitted | a CANCELLED run beside a SUCCESS sibling | picked |
| goal-head | assembly-review-dispatch/goal-head | pick's head is `goal/**` | dispatched with `--rubric .agents/review-goal.md`, no model |
| child-head | assembly-review-dispatch/child-head | `fix/*` head into `goal/**` | default rubric |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-REFLEX-PICK.md"

</details>

### SCAN-REFLEX-BREAKER

Two breakers stand before a dispatch. **(1) Impossible state:** a picked PR that already carries a
reviewer-bot APPROVED at head, or two bot verdicts at head, cannot legitimately be reviewable — the
reflex adds `agent/error` with an `AGENT_ERROR:` comment and does not dispatch; a human removes the
label (`review-reflex.sh:442-456`, after the oracle-fleet#13 loop). **(2) Rounds exhausted:** when
the bot verdicts summed across every PR referencing the same issue reach `REVIEW_ROUNDS_MAX` (12),
the reflex adds `agent/arbitrate` and an `arbitrate` event and does not dispatch — the scan's
`arbitrate` unit takes over (`:497-510`). An unreadable issue-keyed sum falls back to the per-PR
count. A refused label write is a warning and the dispatch is still skipped.

**World:** constructed per row (`IN_*` env).

#### Does a picked PR trip a breaker?

| description | world | env | expect? |
|---|---|---|---|
| clean | — | one verdict, none at head | dispatch |
| error-approved-at-head | — | `IN_V_HEAD=1 IN_V_HEAD_APPROVED=1` | error-trip |
| error-two-at-head | — | `IN_V_TOTAL=2 IN_V_HEAD=2` | error-trip |
| error-label-refused | — | `IN_V_HEAD=1 IN_V_HEAD_APPROVED=1`, label POST fails | error-refused |
| arbitrate-at-cap | — | `IN_ROUNDS_TOTAL=12` | arbitrate-trip |
| arbitrate-label-refused | — | `IN_ROUNDS_TOTAL=12`, label POST fails | arbitrate-refused |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-REFLEX-BREAKER.md"

</details>

### SCAN-REFLEX-REARM

A worker-authored PR that arrived un-armed is invisible to the whole merge path, so the reflex
arms it (`gh pr merge --auto --squash`, the C9 belt, `review-reflex.sh:203-257`) — unless it is a
draft, carries `agent/error`, `major` or `major/awaiting-human`, has a `research/` head, or is
based on anything other than the default branch or a `goal/**` branch (stacked work is un-armed on
purpose). A failed arm is non-fatal; the scan's orphan backstop reports it.

**World:** [`base`](worlds/README.md#family-worlds-fixture-local-worldsname-named-in-rowspsv).

#### Is an un-armed worker PR armed?

| description | world | patch | expect? |
|---|---|---|---|
| worker-unarmed | base | — | armed-both |
| major-not-armed | base | label-major | armed-witness-only |
| awaiting-human-not-armed | base | label-awaiting-human | armed-witness-only |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-REFLEX-REARM.md"

</details>

### SCAN-REFLEX-DECORRELATE

The reviewer is told which model served the fix it reviews, so it can avoid reviewing with the
same one: the reflex reads the newest run report for the PR's issue and passes
`--decorrelate-from <served_model>`; an empty, malformed or model-less report passes nothing
(`review-reflex.sh:413-427`).

⚑ gap: the read is the old proxy's `GET /report/latest?task=issue-<n>`. In the redrawn contract the
fix ride's session is the gateway's and the reviewer's admission names no model; the gateway takes
no exclusion input today (the assembly-review comment, `review-reflex.sh:540-545`) — unverified —
expected to become the gateway's `GET /sessions?task=` read or to retire with the decorrelation.

**World:** constructed proxy answers.

#### What does the reviewer receive?

| description | world | `/report/latest` answer | expect? |
|---|---|---|---|
| served-model | decorrelate-resolution/served-model | valid, with `served_model` | `--decorrelate-from <model>` |
| no-model | decorrelate-resolution/no-model | valid, no `served_model` | nothing passed |
| empty-report | decorrelate-resolution/empty-report | empty | nothing passed |
| malformed-json | decorrelate-resolution/malformed-json | not JSON | nothing passed |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "SCAN-REFLEX-DECORRELATE.md"

</details>
