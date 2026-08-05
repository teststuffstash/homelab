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

⚠ **Read this together with §"Gate the merge, not the launch" below** (operator, 2026-08-05):
breaker #1 is a blast-radius control, **not** the security boundary. The boundary is CODEOWNERS at
merge time. Anything here that looks like an authorisation check is defence in depth and must not
be relied on as more.

The graduation knob for the HARVEST surfaces (**still not built**, verified 2026-08-05 — it exists
in NO XRD or Composition field, only in this paragraph): claim `issueAuthoring.selfQueue`, default
off, letting the coordinator self-label harvested issues, bounded by the existing breakers plus a
per-day rate cap. Flipping it is the operator's per-stack trust call, and it *does* retire
breaker #1 for that stack.

**Two surfaces queue without that knob, and both are deliberate — know which is which:**

- The **alert lane** (below): the responder's shell labels, gated by three fail-closed checks.
- **Leg (c)**: a goal's children are queued by the coordinator, authorised by the fact that a
  HUMAN queued the GOAL — breaker #1 moved UP, not away. That was PROSE until 2026-08-05 (the
  operator asked why circles queues issues with no knob enabled); the scan now **checks it,
  fail-closed**, refusing to emit `goal-decompose` when the goal's `agent/queued` was applied by a
  Bot, or when the actor cannot be read at all.
  ⚠ What the actor test can see: the loop writes as `homelab-agents-1234[bot]` (type `Bot`); the
  operator AND the jail session both write as the operator (type `User`), because the jail holds
  the operator's PAT. **That is correct, not a limitation — jail == human for this process**
  (operator, 2026-08-05). The test blocks THE LOOP from authorising its own goal, which is the
  risk worth blocking.

⚠ **The ALERT lane already crossed this line** (2026-08-04, `agents/coordinator/responder-argo.yaml`
§selfQueue): a responder-filed issue is labelled `agent-fix`+`agent/queued` by the *shell*, not the
session, when three deterministic fail-closed gates pass — not self-referential, a `Touches:`
footprint is declared, and that footprint hits no governance path. No claim knob gates it. So
"bot-authored ⇒ inert" is the rule for the surfaces below, **not** for the alert lane.

## Gate the merge, not the launch — operator ruling, 2026-08-05

The doctrine that supersedes how the rest of this page reads. Written after the operator was asked
why circles queues issues with no `selfQueue` knob enabled:

> *"instead of not launching the issues I would rather gate the merges. The selfQueue knob is a
> good thing to have but it is pretty much worthless — if a GitHub App has `issues:write` for other
> reasons already then doing author==human type checks in some places of the process makes no
> sense; I'm sure the coordinator could tell an -iac worker to change the rule. CODEOWNERS is the
> better defense in the end."*

**Why launch-gating is weak.** Every author/labeller check sits *inside* the loop's own reach. The
App holds `issues:write` because it needs it for ordinary work, so "who applied this label" is a
question the loop can answer about itself, and any rule expressed as code in a repo the loop can
open a PR against is a rule the loop can propose changing. Defence that lives on the same side of
the boundary as the thing being defended is not defence; it is friction that reads like defence,
which is worse than none because it invites reliance.

**Why merge-gating is the real thing.** `CODEOWNERS` + branch protection decide **what lands**, and
that decision is made by GitHub, not by anything the loop runs. It is also the honest unit of risk:
the operator's stated risk model is that *"workers doing extra or bad WORK is fine; merges to master
are the only thing that matters."* A wasted ride costs pennies. A bad merge costs the platform.

**What follows for this page:**

- Breaker #1 and the `selfQueue` knob are **convenience and blast-radius controls**, not security
  boundaries. Keep them cheap. Do not add new author==human checks, and do not let existing ones
  grow into things that get relied upon.
- The one in `coordinator-scan.sh` (a Bot-queued goal may not decompose) **stays as defence in
  depth** — one API call, fails closed — with a comment at the site saying exactly this, so nobody
  mistakes it for the boundary. Retire it the day it costs more than it buys.
- **The target is a fully automatic chain**: `alert → issue → coordinate → fix → review → merge`,
  with no human in the middle, **and the merge gated by what the change actually touches**. Tier 1
  paths land on CI + review alone; an owned path stops and waits for a person. The path decides,
  not the provenance of the issue that started it.

That target is already partly real: the alert lane self-queues from the responder's shell
(§below), the fixer and reviewer are automatic, and the CODEOWNERS path tiers
([iac-lane.md](iac-lane.md) §The platform lane) are what decide whether the last step needs a human.
The remaining work is on the merge side — tier 1 dropping back to unowned once the IAC-G04 sentinel
covers homelab — **not** on adding more checks before the launch.

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

## Leg (c) — goal-budget decomposition — BUILT 2026-08-05

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

> **Operator 2026-08-05: un-deferred.** The revisit condition was met by circles#17 — a
> human-authored, human-queued goal (P0 MVP: bake + page, against a 15-page/91-requirement
> contract, with acceptance criteria and a suggested cap tier). Handed to a *builder*, because
> nothing in the machinery distinguishes a goal from a task, it produced an honest "analysed
> everything, built nothing" twice — and banked nothing between rounds. **No configured cap was
> near binding** (25 turns of 200, $0.06, 41k tokens into a 262k window): the lane was wrong, not
> the budget. That is the case for the clause below.

### Where it lives

| what | where | why there |
|---|---|---|
| trigger | `coordinator-scan.sh` — a new `goal-decompose` clause emitted **instead of** `queued-dispatch` | must branch BEFORE recipe selection, or the launcher FATALs on a missing `.agents/goal.yaml`. Priority slot in the clause list (~L729) |
| instructions | `agents/coordinator/README.md` — a new `## The goal-decompose clause` section | the item session already reads that file per `clause=`; a new play costs a README section, **not** a new role, image or recipe |
| discriminator | `task/goal` label **+** a `Budget: <USD>` body line | the platform's existing split: **labels route, body lines parameterise** (`Touches:`/`Depends-on:`/`Base:` grammar) |
| enforcement | `Σ(child estimator budgets) ≤ parent` in the **launcher pre-flight** | deterministic, beside WIP=1, never LLM-honored |

### Keeping the goal in view — the forest/trees rule (operator, 2026-08-05)

The failure this must not have: *decompose once, then wake only for sub-issues, and the goal is
forgotten.* Until 2026-08-05 that was **guaranteed** rather than likely: the harvest had been
**writing** sub-issue links (`POST …/sub_issues`) since 2026-08-02 and **neither
`coordinator-scan.sh` nor `agent-session.sh` read them back** — the lineage was write-only,
rendering in the GitHub UI and consumed by nothing. Rung 1 shipped the write, not the read. All
three legs below are now built; keep them that way, because each one silently degrades to the old
behaviour if its read is removed:

1. **The coordinator holds the goal, on every child unit.** The scan carries the parent id in the
   unit (a 5th field — FU-114 L3 widened it to 4 for the task class, same move). Any child's unit
   arrives as *"child of goal #N"* and the item brief re-reads the goal before acting.
2. **The worker gets a BOUNDED slice.** The launcher injects a `GOAL CONTEXT` block into the
   environment card from the native parent — **Goal + Acceptance sections only**. ⚠ Injecting the
   whole parent re-imports the context cost decomposition exists to remove; that is precisely how
   circles#17 r1 died. Never the spec tree — children carry their own narrowed `Touches:` and cite
   their own spec rows.
3. **The goal is re-evaluated, not merely survived.** A `goal-review` clause fires when a child
   closes (not only when the last one does): re-read the goal's acceptance against what actually
   shipped, then close, author more children, or stop at the **retro checkpoint** (rung 3 — a
   human retro, never a reflex revert).

The division of labour follows the model-tiering rule: the **coordinator** holds the goal (strong
subscription model, full re-read); the **worker** gets a slice (cheap, budget-capped, bounded
context). Rung 4's sprout-RATE gauge is the health signal — *rate > 1 per run = diverging*.

**Operator rulings 2026-08-05:** (a) **both** discriminators — the `task/goal` label routes,
the `Budget:` line funds; (b) the parent goes to a **non-dispatchable tracking state** initially,
revisit later. Plus: *"there should be some kind of backstop on the goal also"* — nothing wakes a
goal on child traffic alone, so `goal-review` fires on EVERY child closure, and the residual
backstop (a goal whose children are all quiet) is the **meta-coordinator's** for now; the guard
gets designed from observed behaviour rather than guessed at.

### As built

| leg | where |
|---|---|
| `goal-decompose` trigger | `coordinator-scan.sh` — emitted instead of `queued-dispatch`, before recipe selection |
| both plays | `agents/coordinator/README.md` §`goal-decompose`, §`goal-review` |
| `task/goal` label | the claim taxonomy (Composition). ⚠ GitHub caps label descriptions at **100 chars** and `IssueLabels` is authoritative — one over-long description freezes the taxonomy for every claim-owned repo |
| bounded goal context | `agent-session.sh` reads the native parent, injects **Goal + Acceptance only** |
| parent on child units | `coordinator-scan.sh` 5th unit field → `parent=<n>` in the item brief |
| Σ(child caps) ≤ `Budget:` | `agent-session.sh` pre-flight, over open AND closed children, summing `cap_usd` (what the key ALLOWS, not what it forecasts) |
| `goal-review` | `coordinator-scan.sh`, stateless: a child closed after the loop's newest comment on the goal |

Two traps found while building, both of the fail-open kind: `gh issue list` has **no `--argjson`**
(a jq flag) — behind a `|| echo '[]'` that made the budget gate pass everything; and `[ a \> b ]`
is a bashism that can invert the goal-review predicate under another shell. Both are now
sort-based / piped-to-real-jq, and a zero-children result says so aloud instead of failing open.

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
   **The depth half SHIPPED 2026-08-05, in the REVIEWER** (`reviewer-session.sh`): it walks the
   native parent chain of the issue its PR closes and, at depth ≥2, is instructed to emit **no
   `Follow-ups:` section at all** — every finding either blocks (fixed in THIS PR) or is dropped.
   ⚠ It had to move there: the flag was previously applied at HARVEST time, which is too late by
   construction — the PR has merged, so "fix-in-PR" no longer exists and deferral is the only
   option left. The existing HARVEST BAR filters by QUALITY; this filters by POSITION, and they are
   independent. Validated on the chain that prompted it: openrouter-operator #21→#17→#14→#10 walks
   to 3/2/1/0, and #17 (depth 2) is the review that sprouted #21 — under this rule it emits nothing
   to harvest. The BUDGET half is separate and lives in the launcher (Σ child caps ≤ `Budget:`).
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
LAUNCHER (not the dispatcher — dispatch params are launcher-owned, ADR-094) clones and forks from
that branch and tells the agent in the env card to `gh pr create --base <branch>`. `--ref` still
overrides an explicit operator dispatch.

### The `goal/**` convention (operator ruling, 2026-08-05)

A stacked base is named **`goal/<issue>-<slug>`** — it is the integration branch of the GOAL whose
children merge into it (`goal/17-p0-mvp`). Three prefixes, deliberately disjoint:

| prefix | what it is | protected? |
|---|---|---|
| `fix/**` | an ordinary ride's head branch | no |
| `research/**` | researcher arm outputs, pushed to DIRECTLY, human-gated by being un-armed | **no — a ruleset here would gate the arms' own pushes** |
| `goal/**` | a goal's integration base; children merge INTO it | **yes** |

**`goal/**` is protected, and that is what makes feature→goal automatic.** The original rule was
"a declared `Base:` never arms auto-merge", which coupled two different things: *don't let stacked
work reach master by itself* (right) and *don't let a child merge into its own goal branch* (over-broad
— it also cost the reviewer's verdict, since `review-reflex.sh` only reviews ARMED PRs). Operator
ruling: **feature → goal is fine to automate; goal → master stays human.**

⚠ **The protection is a PRECONDITION, not a nicety.** GitHub's auto-merge waits on
branch-protection conditions; with none, arming a PR merges it **on open** — no CI, no review.
Verified before the flip: circles' three rulesets all targeted `~DEFAULT_BRANCH` only, so the
stacked base had no rules at all. `tofu/github/repo_rulesets.tf` now includes
`refs/heads/goal/**` in both `required-checks` and `required-approval`, so a child PR waits for
`ci` + one approving review exactly as a master PR does. **Applied and verified 2026-08-05**:
`GET /repos/…/rules/branches/goal%2F17-p0-mvp` returns `pull_request` + `required_status_checks`.

**Arming is keyed on the `goal/` PREFIX, not on "is this master".** Both the launcher
(`agent-session.sh`) and the re-arm belt (`review-reflex.sh` C9) arm a PR whose base is the repo
default **or** matches `goal/*`; every other non-default base still refuses. That is deliberate and
should not be relaxed to "any stacked base": the prefix is the only thing that carries the ruleset,
so widening the match without widening the protection re-creates merge-on-open.

⚠ **Renaming a base branch closes the PR whose HEAD it is.** Learned the hard way migrating
`research/issue-1-weave` → `goal/17-p0-mvp`: GitHub retargets PRs where the branch is the BASE
(#21, #24 moved cleanly) but CLOSES the one where it is the HEAD — circles#16, the weave PR itself,
reopened as #25 with identical content. `Base:` body lines are text and do not follow a rename
either; they need editing (#17/#18/#19/#22/#23).

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
