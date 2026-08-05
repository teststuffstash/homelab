# Coordinator-authored issues — harvest, authoring, and the sprout index

**Tracked by:** FU-090. **Gate:** TICK-LOG §Loop-safety breaker #1.
**Relates:** FU-086/FU-087 (dispatch + dependencies), FU-044 (revert machinery), ADR-094.

Issue *authoring* has been a jail-LLM practice ([workflow.md](workflow.md) §Triggers emitter
table); the coordinator only filed issues inside meta-4 arbitration. That left a real hole: an
approved PR's `Follow-ups:` section — which the review rubric **requires** to contain issue-ready
bullets — had no owner and died in the review comment.

This document is the design for closing it, plus the accounting substrate the harvest turned out
to need.

## Breaker #1 is the gate for all of it

Every surface below produces **bot-authored, therefore INERT** issues: no `agent-fix`, no
`agent/queued`. A human labels, or nothing runs. That is loop-safety breaker #1 and none of these
legs retire it — leg (c) moves the breaker *up* to the goal issue rather than away.

The graduation knob for the HARVEST surfaces (**not built**): claim `issueAuthoring.selfQueue`,
default off, letting the coordinator self-label harvested issues, bounded by the existing breakers
plus a per-day rate cap. Flipping it is the operator's per-stack trust call, and it *does* retire
breaker #1 for that stack.

⚠ **The ALERT lane already crossed this line** (2026-08-04, `agents/coordinator/responder-argo.yaml`
§selfQueue): a responder-filed issue is labelled `agent-fix`+`agent/queued` by the *shell*, not the
session, when three deterministic fail-closed gates pass — not self-referential, a `Touches:`
footprint is declared, and that footprint hits no governance path. No claim knob gates it. So
"bot-authored ⇒ inert" is the rule for the surfaces below, **not** for the alert lane.

## Leg (a) — follow-up harvest — BUILT 2026-07-27

The C6 / merged item session files each `Follow-ups:` bullet as an issue, with provenance links,
`Depends-on:` lines (FU-087) and the track label inherited.

Mechanism: the scan emits **`merged-closeout`** units for issues closed by a merged PR but still
`agent/in-progress` (21-day window, cap 3/repo/scan, `agent/error` excluded). The item session's
play (coordinator README §merged-closeout) is: verify the outcome on master → flip `agent/done` →
file each review `Follow-ups:` bullet as an inert issue → one closing comment. Verified empty-safe
on all three stacks.

**Visibility slice shipped 2026-07-18:** the scan reports 🌱 bot-authored issues lacking
`agent-fix` per repo, so harvested drafts surface for human triage instead of rotting.

**Consumers registered 2026-07-27:** the harvest is the birth path for the infra-fixer's
expand/contract debt tasks ([iac-lane.md](iac-lane.md) §rollout matrix, row d), and the goal-issue
shape of leg (c) is the FU-105 researcher's dispatch trigger.

## Leg (b) — spec-driven authoring

The ADR-094 janitor tick MAY draft issues from `specs/`/TRACKS gaps, under the same inert gate.

## Leg (c) — goal-budget decomposition — DEFERRED by the operator

A human-authored **and human-queued** `goal` issue carries `budgetUSD` + acceptance criteria. Its
item session MAY author and queue child issues citing the parent, with **Σ(child estimator budgets)
≤ parent budget enforced in the LAUNCHER pre-flight** — deterministic, beside WIP=1, *never*
LLM-honored. The child-issue set is then the reviewable decomposition artifact: "review the result"
applied to planning. The scan surfaces children-of-closed-parents as orphans (the goal-drift belt).
Existing containment carries over unchanged (lane WIP, capacity gates, pod-name keys, FSM,
`agent/error`).

> **Operator 2026-07-24: not yet.** Rollout continues the old-fashioned way — human goal
> decomposition — until the current arc settles. Revisit when a real goal candidate appears.
> A prototype ran 3 days live during meta-9.

## The sprout index — the accounting substrate leg (c) was missing

Operator synthesis 2026-07-31, from the sleep harvest run. This is arguably the "real goal
candidate" leg (c) was waiting for.

**The insight:** the harvest tree already *is* an unbudgeted goal decomposition. What goal-budget
lacked was a **sprout index** — the lineage DAG (issue → PR → harvested child) carrying **depth and
breadth**.

The 2026-07-31 run showed the gap live, in both directions at once:

- With no depth-awareness the reviewer **harvests indiscriminately** — 3 of 5 sprouts were
  self-acknowledged noise (#93/#101/#102, closed).
- And it **defers a same-class-as-the-fix defect it should have completed in-PR** — #96, the 14th
  band column the #57 COALESCE fix missed.

Both failures are the same missing signal.

### The rungs

1. **Structure the lineage as GitHub sub-issues.** Native parent/child gives the tree UI and the
   graph API for free. Today provenance is unparseable prose: *"Harvested from PR #X (issue #Y)"*.
2. **The harvest/reviewer gate reads depth + remaining budget.** Shallow + budget available →
   harvest a real deferral. Deep, or budget low → **fix-in-PR** and collapse the tail.
   Budget blown, or N levels without converging → the **terminal**.
3. **The terminal is a RETRO CHECKPOINT, not a reflex revert** (operator ruling). It means "a good
   place to STOP and rethink": the goal was probably sound but unexpected complexity arose, so a
   **human retro** decides how to proceed — re-scope, collapse-in-PR, or, only in the extreme, a
   lineage-scoped revert via the FU-044 machinery.
4. **Surface it.** The sprout index plus a **sprout-RATE gauge** via the github-exporter (one
   poller) → Grafana node-graph + convergence trend. **Rate > 1 per run = diverging**; that is the
   health KPI.

### Down-payment shipped 2026-07-31

Prompt-only, no index yet — proving the #96/#92 mis-sorts are fixable from the diff alone:
`agents/reviewer-session.sh` gained a **complete-the-fix** narrow-blocking case and a **HARVEST
BAR** (inert / not-a-gap / won't-fix / style stay comments, never `Follow-ups:`).

**The structured sub-issue lineage SHIPPED 2026-08-02** (rung 1): the merged-closeout play
links each harvested issue as a native sub-issue of the ORIGINATING issue (PR provenance stays
in the body; failed link non-fatal + noted) with a ⚠ deep-sprout flag at depth ≥2 — API
round-tripped live before adoption. **Next rungs:** the exporter sprout-RATE gauge (walk
`parent`/sub_issues on the existing GraphQL walk) + the depth-aware harvest gate reading it.

## Touches: the declared footprint (ADR-097, 2026-08-03)

Every authored agent issue carries a **`Touches:`** body line — the expected write surface as
comma-separated paths/globs (`Touches: chassis/**, pyproject.toml`), same unbulleted body-line
grammar as `Depends-on:`. This is where lane knowledge lives now: the authoring LLM judges the
footprint ONCE, reviewably, at creation (sprouts inherit the parent's line and narrow it);
the scan enforces overlap deterministically at dispatch
([workflow.md](workflow.md) §Footprint hold — intersection rules, ceilings and the
escaped-diff belt live THERE). Authoring-side semantics: **omitting the line is safe and means
exclusive** (classic WIP=1); a worker discovering mid-ride that it needs paths outside its
declaration files a new issue for the owning concern (TRACKS rule 2).

## Base: the declared base branch (2026-08-05)

An issue whose work must be built on an **unmerged branch** carries a `Base:` body line, same
unbulleted grammar as `Touches:` and `Depends-on:`:

```
Base: research/issue-1-weave
```

**Absent means master**, so every issue filed before this reads exactly as it did. Present, the
LAUNCHER (not the dispatcher — dispatch params are launcher-owned, ADR-094) does three things from
that one declaration: clones and forks from that branch, tells the agent in the env card to
`gh pr create --base <branch>`, and **refuses to arm auto-merge**. The third is the point: work
stacked on a branch that is itself unmerged and under human evaluation must not land itself. The
re-arm belt (`review-reflex.sh` C9) skips PRs whose base is not the repo default for the same
reason — keyed on the base, not on a branch prefix, because these rides push ordinary `fix/*`
branches. `--ref` still overrides an explicit operator dispatch.

Who writes the line: the issue author, at authoring time, like every other body line — and since
authored issues are inert until a human labels them (breaker #1 above), a wrong `Base:` is caught
in the same read that adopts the issue.

Why a body line and not a label: the value is DATA (which branch), and labels cannot carry it —
the same argument as `Touches:`. First use: circles#17/#18/#19 against the woven spec tree in
circles#16.

The updater needed no change: `update-pr-branch.yml` passes `base: master` and
`require_auto_merge_enabled: true`, so a stacked PR is excluded twice over — it is neither based on
master nor armed. Verified before writing this, rather than assumed.

## Dependencies: native `blockedBy` is primary (FU-111, 2026-08-02)

Authoring a dependency = **create the native edge** (verified live: create, cross-repo, list-ride
all work — `gh api -X POST repos/<owner>/<repo>/issues/<n>/dependencies/blocked_by -F
issue_id=<the BLOCKER's numeric id>`) **and keep the `Depends-on:` body line** during the
transition (the merged-closeout play instructs both since 2026-08-03 — the FU-111 authoring flip) (unbulleted — a markdown bullet slips the scan regex). The scan reads the UNION of
both (same probe path), so either alone gates correctly; the body-line reader retires once
native edges are observed flowing under the App token in scan logs (the one leg a jail probe
cannot verify — FU-108's lesson applied).

## Why sub-issues here and not elsewhere

The scheduler consumes **semantics, not decorations** (recorded during the FU-110 mechanism
review): blocking = native GitHub dependencies (FU-111); operator preference = the pin; grouping
and reporting = milestones and **sub-issues** — which is exactly what lineage is. Sub-issues were
parked "until board scale pays"; the sprout index is what makes them pay.
