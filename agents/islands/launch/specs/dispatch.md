---
id: IF-DISPATCH
use-cases: [UC-1]
schema: dispatch.schema.json
---
# `agent-session.sh <repo> …` — the launcher CLI the scan calls

*Ride this task at this round, or say why not.* The scan (the coordinator brief and
`coordinator-scan.sh`), the retro and research launchers and the seat's drills call the launcher
with [dispatch params](glossary.md#dispatch-params); it answers with a pod, or with one stderr
line and an exit code before any pod exists. Everything the launcher can derive from the issue,
the claim or the PR it derives here — the base branch, whether the PR is armed, the recipe class,
the goal's funding — so the caller never has to remember it (ADR-094: dispatch params are
launcher-owned).

## Interface — the machine half

| requirement | schema path | exit codes | stderr verdict line |
|---|---|---|---|
| [LAUNCH-DISPATCH-ARGV](#launch-dispatch-argv) | `argv` | 2 | `unknown arg: <flag>` |
| [LAUNCH-DISPATCH-EXIT](#launch-dispatch-exit) | `exit` | 0 · 1 · 2 · 3 | `PREFLIGHT REFUSED: …`, `FATAL: …`, `→ dispatch deferred — …` |
| [LAUNCH-PREFLIGHT-BODY](#launch-preflight-body) | `argv.task`, `exit` | 1 | `PREFLIGHT REFUSED: malformed machine block on <ref> …` |
| [LAUNCH-PREFLIGHT-ARM](#launch-preflight-arm) | `derived.arm` | — | `→ Base: …`, `→ --no-arm derived: …` |
| [LAUNCH-PREFLIGHT-DUPLICATE](#launch-preflight-duplicate) | `exit` | 0 · 3 | `PREFLIGHT REFUSED: … (FU-042)`, `PREFLIGHT REFUSED (atomic): …` |
| [LAUNCH-PREFLIGHT-GOAL-BUDGET](#launch-preflight-goal-budget) | `derived.goal`, `exit` | 1 | `PREFLIGHT REFUSED: the decomposition of goal #<n> overruns its Budget.` |
| [LAUNCH-DISPATCH-RECIPE](#launch-dispatch-recipe) | `argv.recipe`, `derived.recipe` | 2 | `FATAL: <recipe> is not parseable YAML …` |

## Requirement index

| Requirement | section | Status |
|---|---|---|
| [LAUNCH-DISPATCH-ARGV](#launch-dispatch-argv) | the call | 🚧 WIP — no evidence pipeline yet (fixture: `argv-max-turns`) |
| [LAUNCH-DISPATCH-EXIT](#launch-dispatch-exit) | the call | 🚧 WIP — no evidence pipeline yet; no fixture holds the whole vocabulary (each family pins its own `RC`) · ⚖ the two defer conventions |
| [LAUNCH-PREFLIGHT-BODY](#launch-preflight-body) | preflight | 🚧 WIP — no evidence pipeline yet (fixtures: `preflight-malformed-block`, `base-arm-authoring`) |
| [LAUNCH-PREFLIGHT-ARM](#launch-preflight-arm) | preflight | 🚧 WIP — no evidence pipeline yet (fixtures: `base-arm-*`, `major-arm-guard-*`) |
| [LAUNCH-PREFLIGHT-DUPLICATE](#launch-preflight-duplicate) | preflight | 🚧 WIP — no evidence pipeline yet (fixtures: `fu042-guard-a`, `fu042-wip-cap`; the existing-pod and pod-create-race arms have none) |
| [LAUNCH-PREFLIGHT-GOAL-BUDGET](#launch-preflight-goal-budget) | preflight | 🚧 WIP — no evidence pipeline yet (fixtures: `goal-ancestor`, `goal-budget-gate`, `goal-budget-refusal`) |
| [LAUNCH-DISPATCH-RECIPE](#launch-dispatch-recipe) | the recipe | 🚧 WIP — no evidence pipeline yet; no fixture (`recipe-lint.sh` has no replay row; the `task/<class>` selection and the splice fallbacks are unpinned) |

## The call

### LAUNCH-DISPATCH-ARGV

The first argument is the repo (the claim's `repos[].name`, also the pod's namespace). Every other
argument is a flag (`agents/agent-session.sh` `REPLAY:argv-parse`, :100–123): `--task`
`issue-<N>` | `pr-<N>` | `research-<N>-<slug>`, `--round <r>` (default 1), `--recipe <path>` (the
launcher builds the harness command — never `--run` with it), `--work-branch <b>` (a fix round
resumes that PR branch), `--ref <base>`, `--max-turns <n>`, `--context-repo <url>` (repeatable),
and the operator overrides `--harness`, `--model`, `--docker`, `--size`, `--no-arm`,
`--openrouter-secret`, `--no-attach`. A flag the grammar does not know is a usage refusal, never
swallowed — a bare `--help` used to become the repo name. `--max-turns` sets both harnesses' caps
at once (`GOOSE_MAX_TURNS` and `CLAUDE_MAX_TURNS`), because the harness is decided after the parse.
`--model` is an override on the old path and a refusal on a gateway ride
([LAUNCH-ADMIT-LAUNCHER](admission.md#launch-admit-launcher)).

**World:** `launcher-vars` — the argv is the row's whole condition.

#### What the parse leaves behind

Legend: `argv` = the flags after the repo; `goose_max_turns?` / `claude_max_turns?` = the
exported caps (`<unset>` = not exported).

| description | world | argv | goose_max_turns? | claude_max_turns? | rc? | stderr? |
|---|---|---|---|---|---|---|
| documented-goose | launcher-vars | `--max-turns 200` | 200 | 200 | 0 | — |
| documented-claude | launcher-vars | `--max-turns 80` | 80 | 80 | 0 | — |
| no-flag | launcher-vars | (none) | `<unset>` | `<unset>` | 0 | — |
| unknown-flag | launcher-vars | `--bogus-flag` | — | — | 2 | `unknown arg: --bogus-flag` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-DISPATCH-ARGV.md"

</details>

### LAUNCH-DISPATCH-EXIT

The exit code is the caller's whole machine answer; the stderr line is the human one. **0** — the
ride ran (headless: the launcher followed the pod to its end), or it was deferred by a read the
launcher could not make (the issue, its comments, the newest review, the CI log, `gh pr list`) or,
on the old path, by a capacity gate (the Go window, both subscription rails latched, the account
credit floor). **1** — a refusal about the work: a malformed machine block, a goal over budget, a
chainless stack without a routed verdict; and a capacity defer from the gateway or the old router.
**2** — a usage refusal: argv, a `--recipe` that does not exist or does not parse, `--model` or an
interactive ride under the gateway, an argv over the 128 KiB element ceiling. **3** — a refusal
about the cluster: a duplicate PR or pod for this (task, round), the WIP cap, a poisoned
`devbox.lock`, a session key expiring within 30 minutes, `pr-open.sh` missing
(`agents/agent-session.sh`: 92, 120, 293–329, 628, 649, 745–755, 1446, 1500, 1631, 1672–1753,
1772–1984, 2103, 2428, 2842–3016, 3049).

⚖ **A deferral exits 0 or 1 depending on who deferred.** The pre-flight reads and the old capacity
gates exit 0 (the dispatcher sees success and the next pass retries); a gateway `defer` and a
router `defer` exit 1 with the same "the next pass retries" meaning. A caller cannot tell a
deferral from a completed ride by the code alone — it reads the stderr line. The redrawn contract
is one deferral code with the reason on the line (unverified — expected once the old gates retire:
the gateway defer is then the only capacity deferral, and the read deferrals can take its code).

**World:** `launcher-vars`.

#### Which code a verdict carries

Legend: `verdict` = the condition the launcher meets; `rc?` = its exit code; `pod?` = whether a pod
exists afterwards.

| description | world | verdict | rc? | pod? |
|---|---|---|---|---|
| the ride ran | launcher-vars | headless ride followed to its end | 0 | yes (self-terminating) |
| an unreadable directive defers ⚖ | launcher-vars | `gh api …/issues/<n>/comments` fails | 0 | no |
| a gateway defer ⚖ | stack-platform · gw-defer | `decision: defer` | 1 | no |
| a malformed machine block | launcher-vars | `Base:` block with an unknown key | 1 | no |
| an unknown flag | launcher-vars | `--bogus-flag` | 2 | no |
| `--model` on a gateway ride | stack-platform | `--model x` with `AGENT_GATEWAY=sessions` | 2 | no |
| a second open PR for the issue | issue-1175-fix-round | two open PRs closing #N | 3 | no |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-DISPATCH-EXIT.md"

</details>

## Preflight — refuse before a pod exists

### LAUNCH-PREFLIGHT-BODY

Every body-grammar read goes through the one parser (`agents/issue_body.py`, ADR-122 (3);
`agents/agent-session.sh` `REPLAY:preflight-body-parser`, :48–70): the `---`-fenced machine block
first, the legacy line form as the transition fallback, which prints one
`LEGACY-GRAMMAR <key> <repo>#<n>` line to stderr per fall-through (the migration meter, never
suppressed). A **malformed** block — an unknown key, an indented line, a duplicate key, an
unterminated fence — is not "no declaration": the author believes they declared one, so the
launcher refuses with exit 1 before any pod, branch or key exists. An unreachable parser (no
python3) is the one degrade: loud, and the key reads as absent. `Base:` is read this way
(`REPLAY:base-declared-read`, :1135); `Touches:` too, when the claim declares `specs`
([LAUNCH-CARD-SPECS-PROCESS](context.md#launch-card-specs-process)); `Budget:` through
`goal-budget.sh` on the same parser.

**World:** `launcher-vars` with the issue body as the row's input.

#### The `Base:` read

Legend: `body` = how the issue declares `Base: goal/12-slug`; `arm?` = whether the PR will be
armed; `meter?` = the `LEGACY-GRAMMAR` line.

| description | world | body | arm? | meter? | rc? |
|---|---|---|---|---|---|
| block-authored | launcher-vars | `---` block, `Base: goal/12-slug` | armed | none | 0 |
| legacy-line | launcher-vars | column-0 `Base: goal/12-slug` | armed | `LEGACY-GRAMMAR Base teststuffstash/homelab#1431` | 0 |
| block-malformed | launcher-vars | `---` block with an unknown key `Nope` | — | — | 1 |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-PREFLIGHT-BODY.md"

</details>

### LAUNCH-PREFLIGHT-ARM

Whether the ride's PR is armed for auto-merge is **derived**, never asked for (`--no-arm` stays
as an explicit operator override; finalize reads `AGENT_ARM_PR=0`). A declared `Base:` that is
`master` or a `goal/**` integration branch forks from it and arms; any other base forks from it,
opens the PR against it and does not arm — stacked work on an unmerged branch is human-gated by
construction (`REPLAY:base-arm-guard`, :1161). An explicit `--ref` wins over the declaration. A
research recipe into a `goal/**` base arms (the human read is the goal's assembly); into anything
else it does not (`REPLAY:research-arm-guard`, :1245). A fix round on an existing branch reads that
branch's open PR: an un-armed `major` PR stays un-armed (the human-merge lane), and an unreadable PR
list is not armed either — the launcher does not arm what it cannot classify
(`REPLAY:major-arm-guard`, :1263).

> **External:** verify during implementation — `gh pr list --json autoMergeRequest` returns `null` for a PR without auto-merge enabled (the worlds record it so; not read against GitHub's docs).

**World:** one recorded issue (#1349 for the base rows, #1515 and the renovate branches for the
major rows) per fixture.

#### Arming

Legend: `base` = the declared/derived base; `recipe` = fix or research; `work_branch_pr` = the
open PR of `--work-branch` (`—` = no work branch); `no_arm?` = the derived `NO_ARM`.

| description | world | base | recipe | work_branch_pr | no_arm? |
|---|---|---|---|---|---|
| base-arm-master | base-arm-master | master | fix | — | empty (armed) |
| base-arm-nonprotected | base-arm-nonprotected | feature-x | fix | — | 1 |
| base-arm-research-master | base-arm-research-master | master | research | — | 1 |
| base-arm-research-goal | base-arm-research-goal | goal/418-answers-match-the-printed-law | research | — | empty (armed) |
| major-arm-guard-ordinary | major-arm-guard-ordinary | master | fix | an ordinary open PR | empty (armed) |
| major-arm-guard-armed-major | major-arm-guard-armed-major | master | fix | `major`, auto-merge armed | empty (armed) |
| major-arm-guard-unarmed-major ⚖ | major-arm-guard-unarmed-major | master | fix | `major` #2033, not armed | 1 |
| major-arm-guard-unreadable ⚖ | major-arm-guard-unreadable | master | fix | the list read fails | 1 |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-PREFLIGHT-ARM.md"

</details>

### LAUNCH-PREFLIGHT-DUPLICATE

One ride per (issue, round): the pod name is the idempotency key
([LAUNCH-POD-IDENTITY](pod.md#launch-pod-identity)), and before it the launcher reads the repo's
open PRs. An issue with two open PRs refuses; an issue with one open PR refuses a fresh ride (resume
it with `--work-branch`); a `--work-branch` that is not that PR's branch refuses; an unreadable PR
list defers (exit 0). A namespace already running `AGENT_WIP_LIMIT` agent pods refuses (exit 3,
`REPLAY:fu042-wip-cap`, :1725). A pod that already exists for the (task, round) refuses (:3016), and a
create that loses a race refuses atomically (:3049) — an unreadable race probe keeps the context
bundle rather than deleting what a live pod may have mounted.

**World:** `fu042-guard-a` (recorded open-PR lists for #344/#351/#352/#353), `launcher-vars` + a
`kubectl` pod list for the WIP cap.

#### Duplicates and the cap

A PR **strongly links** an issue when its body carries a closing keyword (`implements`, `close[sd]`,
`fix(e[sd])`, `resolve[sd]`, optional colon) as a whole word before `#N`; a bare mention, or a
keyword that is the tail of a longer word (`unresolved #352`), does not.

Legend: `issue` = the dispatched issue; `open_prs` = what the world's open PRs say about it;
`work_branch` = `--work-branch` (`—` = none); `running` = agent pods Running in the namespace /
the limit. One world, six arms.

| description | world | issue | open_prs | work_branch | running | rc? |
|---|---|---|---|---|---|---|
| MENTION_ONLY | fu042-guard-a | #344 | #366 mentions it in prose | — | — | continues |
| STRONG_LINK | fu042-guard-a | #351 | #366 `Fixes #351` | — | — | 3 |
| RESUME_MATCH | fu042-guard-a | #351 | #366 `Fixes #351` | #366's head | — | continues (resume line) |
| RESUME_MISMATCH | fu042-guard-a | #351 | #366 `Fixes #351` | another branch | — | 3 |
| MIDWORD_MENTION ⚖ | fu042-guard-a | #352 | #400 says `unresolved #352` | — | — | continues |
| DUPLICATE_PRS | fu042-guard-a | #353 | #401 and #402 both `Fixes #353` | — | — | 3 |
| fu042-wip-cap | launcher-vars | test-project | none | — | 3 / 3 | 3 |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-PREFLIGHT-DUPLICATE.md"

</details>

### LAUNCH-PREFLIGHT-GOAL-BUDGET

A child of a funded Goal may not ride past the Goal's `Budget:`. The launcher walks the issue's
native parent chain up to the nearest `task/goal` or `Budget:` ancestor (`REPLAY:goal-ancestor`,
:1300; ADR-102's post-launch lane puts a bucket between child and goal); without one, the direct
parent is used for the card only — no funded goal, nothing to gate. With a goal, `goal-budget.sh`
sums actual spend for settled children, cap reservations for live keys and this dispatch, and
compares against `Budget:` (`REPLAY:goal-budget-gate`, :1358). **exhausted** refuses with exit 1
and keeps ONE refusal comment on the goal, created once and re-stated in place when the numbers
move (`REPLAY:goal-budget-refusal`, :1362; an unreadable comment list posts nothing and the refusal
still stands). **terminal** (`goal/validated|reverted|abandoned`) passes through. An unreachable
ledger or a degraded descendant walk charges every child its full cap (the conservative fallback).
The goal's Goal + Acceptance sections reach the worker through the card
([LAUNCH-CARD-FACTS](context.md#launch-card-facts)).

**World:** `homelab-278-tree` / `circles-constructed-parents` for the walk; `gate-homelab-278`
and its two variants for the gate.

#### The walk

Legend: `issue` = the dispatched child; `gate_subject?` = the issue the budget gate reads.

| description | world | issue | gate_subject? | hops? |
|---|---|---|---|---|
| bucket-child | homelab-278-tree | homelab#367 | #278 | 1 |
| direct-child | homelab-278-tree | homelab#291 | #278 | 0 |
| none-fallback | circles-constructed-parents | circles#88 | #61 (card only, no gate) | — |
| unlabelled-budget | circles-constructed-parents | circles#90 | #62 | 0 |
| child-with-budget-and-parent | circles-constructed-parents | circles#92 | #62 | 1 |

#### The gate

Legend: `goal_state` = the goal's labels/body patch; `verdict?` = the gate's verdict; `rc?` = exit
(0 = the dispatch continued past the pre-flight).

| description | world | goal_state | verdict? | rc? |
|---|---|---|---|---|
| terminal-validated | gate-homelab-278 | `goal/validated` | terminal | 0 |
| terminal-reverted | gate-homelab-278 | `goal/reverted` | terminal | 0 |
| terminal-abandoned | gate-homelab-278 | `goal/abandoned` | terminal | 0 |
| open-within | gate-homelab-278 | `Budget: $5`, Σ $3.0 | within | 0 |
| cross-repo-within | gate-homelab-278-cross | `Budget: $5`, Σ $4.5 | within | 0 |
| open-over-budget | gate-homelab-278 | `Budget: $1` | exhausted | 1 |
| post-launch-open | gate-homelab-278 | post-launch, open | exhausted | 1 |
| open-over-budget-degraded ⚖ | gate-homelab-278-no-ledger | `Budget: $1`, ledger unreachable | exhausted (cap-sum) | 1 |
| colliding-number-exhausted | gate-homelab-278-cross | `Budget: $1`, a cross-repo child number collides | exhausted | 1 |
| degraded-walk-midtree-fail ⚖ | gate-homelab-278-cross | a descendant fetch fails mid-tree | cap-sum fallback | per the sum |
| subscription-ride-within ⚖ | gate-homelab-278 | `Budget: $1`, subscription-rail ride | within ($0.0) | 0 |
| subscription-ride-rows | gate-homelab-278-cross | `Budget: $1`, subscription-rail rows | exhausted | 1 |

#### The refusal comment

Legend: `existing` = the goal's prior refusal comment; `action?` = what the launcher writes.

| description | world | existing | action? |
|---|---|---|---|
| first-touch | launcher-vars | none | create one |
| interleaved | launcher-vars | an older body, other comments since | patch it in place |
| legacy | launcher-vars | a legacy `AGENT_BUDGET_REFUSED:` comment without the marker | patch it in place |
| unchanged | launcher-vars | the same body | none |
| unreadable | launcher-vars | the comment list read fails | none (refusal still stands) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-PREFLIGHT-GOAL-BUDGET.md"

</details>

## The recipe

### LAUNCH-DISPATCH-RECIPE

The dispatcher passes the default recipe (`.agents/fix.yaml` in the repo's clone); an issue
carrying a `task/<class>` label rides the sibling `.agents/<class>.yaml` when one exists, else the
default with one line saying so (:1462 — deterministic, never model-picked;
[../docs/fixer-context.md](../docs/fixer-context.md) §L3). The chosen recipe must parse as YAML
before any pod exists (`agents/recipe-lint.sh`, exit 2 with the reproduce command, :1497); the card
is spliced at its `{{PLATFORM_ENV_CARD}}` marker, else after its `instructions: |` key, else the
ride goes without a card and says so; a splice that breaks the YAML falls back to the un-carded
recipe (a launcher bug, not repo content). The recipe text then rides base64-encoded inside the
harness command ([LAUNCH-POD-HARNESS-CMD](pod.md#launch-pod-harness-cmd)). unverified — expected:
every recipe in a claim repo carries the marker (`scripts/stack-lint.sh` runs `recipe-lint.sh`; the
marker itself is unlinted).

#### Selection and splice

Legend: `label` = the issue's `task/*` label; `sibling` = whether `.agents/<class>.yaml` exists;
`recipe_shape` = marker / `instructions:` only / neither / unparseable.

| description | world | label | sibling | recipe_shape | recipe? | card? | rc? |
|---|---|---|---|---|---|---|---|
| the default recipe, marker present | launcher-vars | none | — | marker | fix.yaml | at the marker | 0 |
| a task class with its recipe | launcher-vars | `task/build` | yes | marker | build.yaml | at the marker | 0 |
| a task class without its recipe | launcher-vars | `task/docs` | no | marker | fix.yaml | at the marker | 0 |
| no marker ⚖ | launcher-vars | none | — | `instructions:` only | fix.yaml | after `instructions:` | 0 |
| no marker, no instructions | launcher-vars | none | — | neither | fix.yaml | none (WARN) | 0 |
| an unparseable recipe | launcher-vars | none | — | unparseable | — | — | 2 |

_Evidence: none yet — unverified._
