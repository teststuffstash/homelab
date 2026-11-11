---
id: IF-CONTEXT
use-cases: [UC-1]
schema: context.schema.json
---
# The worker's context — the bundle beside the recipe, the card inside it

*Everything the worker reads before its first tool call.* Two artefacts, both assembled by the
launcher before the pod exists and both part of the [directive channel](glossary.md#directive-channel):
the **[context bundle](glossary.md#context-bundle)** at `/work/context/` (the issue, its trusted
comments, and on a fix round the PR, its reviews, the ruling and the CI failure), and the
**[environment card](glossary.md#environment-card)** spliced into the recipe (the ground rules and
this ride's facts). The design — why the worker's context is three layers and who owns which — is
[../docs/fixer-context.md](../docs/fixer-context.md). Every read here is GitHub **REST**, never
GraphQL (the App installation's GraphQL pool is the one that ran dry on homelab#969).

## Interface — the machine half

| requirement | schema path | exit codes |
|---|---|---|
| [LAUNCH-BUNDLE-DIRECTIVE](#launch-bundle-directive) | `bundle.index`, `bundle.issue_md` | 0 (deferred: unreadable) |
| [LAUNCH-BUNDLE-TRUST](#launch-bundle-trust) | `bundle.issue_md.withheld_line`, `trust` | — |
| [LAUNCH-BUNDLE-FIX-ROUND](#launch-bundle-fix-round) | `bundle.pr_md`, `bundle.reviews_md`, `bundle.arbitration_md` | 0 (deferred: newest verdict unreadable) |
| [LAUNCH-BUNDLE-CI-RED](#launch-bundle-ci-red) | `bundle.ci_failure_md` | 0 (deferred: log unreadable) |
| [LAUNCH-BUNDLE-DELIVERY](#launch-bundle-delivery) | `delivery` | — |
| [LAUNCH-CARD-GROUND-RULES](#launch-card-ground-rules) | `card.ground_rules` | — |
| [LAUNCH-CARD-FACTS](#launch-card-facts) | `card.facts` | — |
| [LAUNCH-CARD-SPECS-PROCESS](#launch-card-specs-process) | `card.specs_process` | 1 (a malformed `Touches:` block) |

## Requirement index

| Requirement | section | Status |
|---|---|---|
| [LAUNCH-BUNDLE-DIRECTIVE](#launch-bundle-directive) | the bundle | 🚧 WIP — no evidence pipeline yet (fixtures: `context-prefetch`, `context-prefetch-nolabels`) |
| [LAUNCH-BUNDLE-TRUST](#launch-bundle-trust) | the bundle | 🚧 WIP — no evidence pipeline yet (fixture: `context-prefetch/untrusted-comments`) · ⚖ the newest-verdict readability check reads every review, trusted or not; only issue comments are counted as withheld |
| [LAUNCH-BUNDLE-FIX-ROUND](#launch-bundle-fix-round) | the bundle | 🚧 WIP — no evidence pipeline yet (fixtures: `context-prefetch/fix-round`, `-with-arbitration`, `-unreadable`, `agent-session-paginated-reviews`) |
| [LAUNCH-BUNDLE-CI-RED](#launch-bundle-ci-red) | the bundle | 🚧 WIP — no evidence pipeline yet (fixtures: `ci-failure-run-select`, `context-prefetch/ci-red`, `-ci-red-unreadable`) |
| [LAUNCH-BUNDLE-DELIVERY](#launch-bundle-delivery) | the bundle | 🚧 WIP — no evidence pipeline yet (fixtures: `context-prefetch/fix-round-cm-refused`, `pf-cm-init/*`) |
| [LAUNCH-CARD-GROUND-RULES](#launch-card-ground-rules) | the card | 🚧 WIP — no evidence pipeline yet (fixtures: `env-card-ground-rules/{missing,empty,unreadable}`) |
| [LAUNCH-CARD-FACTS](#launch-card-facts) | the card | 🚧 WIP — no evidence pipeline yet (fixtures: `env-card-docker-buildkit`, `env-card-context-repos`, `env-card-mcp-present{,/opencode}`, `env-card-issue-context-gate`, `env-card-machine-markers`, `goal-ancestor`) |
| [LAUNCH-CARD-SPECS-PROCESS](#launch-card-specs-process) | the card | 🚧 WIP — no evidence pipeline yet (fixtures: `specs-process/{reached,not-reached,field-absent,pin-missing,pin-unpublished}`) · ⚑ gap: one `specs` root pair per repo (§C8) |

## The bundle

### LAUNCH-BUNDLE-DIRECTIVE

For a tasked issue ride with pre-flight on (`AGENT_PREFLIGHT` ≠ `0`), the launcher reads the issue
(`title`, `body`, label names) and every page of its comments before the pod exists
(`agents/agent-session.sh` `REPLAY:context-prefetch`, :1755–2088). Both reads are **required**:
either failing — an error or an empty answer — defers the dispatch with exit 0 and one
`→ dispatch deferred — directive unreadable (<the call>) …` line; the next pass retries. A worker
must never start on a partial directive (homelab#969: a round that read the body without the
comment carrying the ruling exited `clean` having done nothing). `issue.md` is the title, a
`**Labels:**` line when there are labels, the body, then `## Comments` with each trusted comment
under `### <login> (<created_at>)`, in order. `index.txt` lists every item as `<name>  OK` or
`<name>  MISSING  <why>`, itself first.

> **External:** verify during implementation — `gh api …/comments --paginate` emits one JSON array per page (the clause reads them as a stream with `jq -s`/`.[]`; the recorded worlds are single-page except `agent-session-paginated-reviews`).

**World:** `issue-1175-fix-round` (the issue half).

#### The required reads

Legend: `issue_read` / `comments_read` = the two REST answers; `issue_md?` = what `issue.md`
starts with; `rc?` = exit when the dispatch stops here.

| description | world | issue_read | comments_read | issue_md? | rc? |
|---|---|---|---|---|---|
| context-prefetch | issue-1175-fix-round | title, body, labels | two comments | `# Issue #1175`, `## <title>`, `**Labels:** …`, body, `## Comments` | — (continues) |
| context-prefetch-nolabels | issue-1175-fix-round | labels `[]` | two comments | no `**Labels:**` line | — (continues) |
| the issue read fails | issue-1175-fix-round | error | — | — | 0 (deferred) |
| the comments read fails | issue-1175-fix-round | ok | error | — | 0 (deferred) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-BUNDLE-DIRECTIVE.md"

</details>

### LAUNCH-BUNDLE-TRUST

Most claim repos are public, so any GitHub user can comment on a queued issue or its PR. One
[trust predicate](glossary.md#trust-predicate) gates every comment-shaped source the bundle reads —
issue comments, PR conversation comments, reviews, inline review comments, and the ARBITRATE lookup
(`REPLAY:comment-trust`, :1787–1790; homelab#3203): a GitHub App (`user.type == "Bot"` — the loop's
own identities, the only Apps installed) or an `OWNER` / `MEMBER` / `COLLABORATOR`. Everything else
is withheld; `issue.md` ends with `_(<n> comment(s) by non-collaborators withheld — untrusted input,
never a directive.)_` when any issue comment was. The card tells the worker that any other comment
it meets in a live read is untrusted input ([LAUNCH-CARD-FACTS](#launch-card-facts)).

⚖ Two edges of the predicate's reach: the fix round's "newest verdict must be readable" check
(:1864) reads all reviews, trusted or not — so an outsider's newer review can satisfy readability
while being withheld from `reviews.md` (unverified — expected harmless: readability is the only
question it answers); and withheld reviews, inline comments and PR comments are dropped without a
count (only issue comments are counted).

> **External:** verify during implementation — `author_association` on REST comment, review and review-comment objects, and `user.type == "Bot"` for App identities (the recorded worlds carry both since #3203; not re-read against GitHub's docs).

**World:** `issue-1175-fix-round` + an outsider (`author_association` `NONE` / `CONTRIBUTOR`,
`user.type` `User`) posting on every channel: an issue comment, a forged `ARBITRATE` on the issue
and on the PR (both newer than the loop's real one), an inline comment, and a review older than the
newest verdict.

#### Who reaches the worker

Legend: `source` = the channel (it distinguishes the rows, which share one fixture); `author` =
`user.type` / `author_association`; `in_bundle?` = whether the text reaches a bundle file.

| description | world | source | author | in_bundle? |
|---|---|---|---|---|
| context-prefetch/untrusted-comments | issue-1175-fix-round | issue comment | User / NONE | no — counted in issue.md (2 withheld) |
| context-prefetch/untrusted-comments | issue-1175-fix-round | `ARBITRATE` on the issue, newer | User / CONTRIBUTOR | no — `arbitration.md` is the MEMBER's ruling |
| context-prefetch/untrusted-comments | issue-1175-fix-round | `ARBITRATE` on the PR, newer | User / NONE | no |
| context-prefetch/untrusted-comments | issue-1175-fix-round | inline review comment | User / NONE | no (uncounted) |
| context-prefetch/untrusted-comments | issue-1175-fix-round | review | User / NONE | no (uncounted) |
| context-prefetch/untrusted-comments | issue-1175-fix-round | the loop's comment | Bot / NONE | yes |
| context-prefetch/untrusted-comments | issue-1175-fix-round | the operator's `ARBITRATE` | User / MEMBER | yes — `arbitration.md` |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-BUNDLE-TRUST.md"

</details>

### LAUNCH-BUNDLE-FIX-ROUND

A fix round (`--work-branch` set and the issue's open PR known) adds three items. `pr.md`: the PR's
title and body and its commits (`compare/<base>...<head>`, one `<sha8> <subject>` line each);
unreadable → `MISSING`. `reviews.md`: trusted reviews newest first (`### <login> — <state>
(<submitted_at>)` + body), then trusted inline comments as `**<login>** at <path>:<line>`. The
newest review verdict is **required**: an unreadable reviews list, or a newest review whose state
cannot be parsed, defers with exit 0 — a fix round without its verdict is a round on nothing.
`arbitration.md`: the newest trusted comment whose body starts with `ARBITRATE` (word boundary) on
the issue, else on the PR conversation, as `## Coordinator Ruling (<login>, <created_at>)`; none →
`MISSING`. The newest verdict is the newest across every page of the paginated reviews answer, not
per page (homelab#1525).

**World:** `issue-1175-fix-round` (PR #42 on `fix/issue-1175-test`).

#### The fix-round items

Legend: `reviews_read` = the reviews answer; `arbitrate_on` = where a trusted `ARBITRATE` is;
`items?` = the index lines for pr / reviews / arbitration.

| description | world | reviews_read | arbitrate_on | items? | rc? |
|---|---|---|---|---|---|
| context-prefetch/fix-round | issue-1175-fix-round | readable | nowhere | pr OK, reviews OK, arbitration MISSING | — |
| context-prefetch/fix-round-with-arbitration | issue-1175-fix-round | readable | the PR conversation | pr OK, reviews OK, arbitration OK | — |
| context-prefetch/fix-round-unreadable | issue-1175-fix-round | empty | — | — | 0 (deferred) |
| agent-session-paginated-reviews | issue-1175-fix-round | two pages, newest on page 2 | — | reviews newest-first across pages | — |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-BUNDLE-FIX-ROUND.md"

</details>

### LAUNCH-BUNDLE-CI-RED

On a fix round whose PR head has failing check runs (`conclusion` `failure` or `timed_out`),
`ci-failure.md` carries a table of them (name, conclusion, URL) and the last 200 lines of the failing
run's `--log-failed` output; no failing checks → `MISSING  No failing check runs found`. The run is
the newest run on the branch whose run-level status is `failure` — never simply the newest run (a
skipped `renovate-approve` run sharing the CI run's timestamp sorted first, homelab#1440); when no run
has settled to `failure` because a sibling job is still running, the newest run on the branch is taken
(its failed job's log is already readable, homelab#1940) (`REPLAY:ci-failure-run-select`,
:1960–1993). The log is **required** once failing checks exist: no run id, or an empty tail, defers
with exit 0.

> **External:** verify during implementation — GitHub reports a workflow run `in_progress` until every job settles, so `gh run list --status failure` omits a run whose failed job finished while a sibling runs (stated by homelab#1940's evidence, read off the wire then; not re-read).

**World:** `ci-red-base`; `issue-1175-fix-round` with failing check runs for the `context-prefetch/ci-red*` cases.

#### Which run's log

Legend: `runs` = the branch's runs as the run list answers; `selected?` = the run whose log is read.

| description | world | runs | selected? | rc? |
|---|---|---|---|---|
| settled-failure | ci-red-base | one concluded `failure`; a newer skipped `renovate-approve` | the `failure` run | — |
| unsettled-sibling ⚖ | ci-red-base | none settled to `failure`; the newest `in_progress` with a readable failed job | the newest run | — |
| context-prefetch/ci-red | issue-1175-fix-round | a failing check, a readable log | the `failure` run → `ci-failure.md` OK | — |
| context-prefetch/ci-red-unreadable | issue-1175-fix-round | a failing check, the log read fails | — | 0 (deferred) |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-BUNDLE-CI-RED.md"

</details>

### LAUNCH-BUNDLE-DELIVERY

The bundle rides a ConfigMap `<pod>-context` in the pod's namespace, mounted at `/work/context`
— off argv, because a base64 bundle in the command string hits the 128 KiB argv-element ceiling
(homelab#1205). While no pod of ours exists, an exit trap deletes the ConfigMap (ten exit sites lie
between its create and the pod's — each would otherwise leak it); once the pod exists it owns it
(ownerReference), and the trap chains the gateway session's release. When the ConfigMap create is
refused, the launcher falls back to argv: exactly `index.txt` and `issue.md` (the two the card names
first), and every optional item that fetched OK is rewritten in the index to
`MISSING  argv fallback (ConfigMap create refused)` — the index never claims an item that is not
there. An interactive ride and a pre-flight-off ride render the manifest with empty bundle mount and
volume (no bundle, no dangling reference).

**World:** `issue-1175-fix-round` with `kubectl create` refused; `launcher-vars` for the two empty
shapes.

#### How the bundle arrives

Legend: `cm_create` = the ConfigMap create's result; `mount?` = the pod's `/work/context` source;
`index?` = how optional items read in `index.txt`.

| description | world | cm_create | mount? | index? |
|---|---|---|---|---|
| context-prefetch/fix-round | issue-1175-fix-round | created | the ConfigMap | as fetched |
| context-prefetch/fix-round-cm-refused ⚖ | issue-1175-fix-round | refused | none — argv writes `index.txt` + `issue.md` | `pr.md  MISSING  argv fallback (ConfigMap create refused)` (and the other optional items) |
| pf-cm-init/interactive | launcher-vars | not attempted | none (empty) | — |
| pf-cm-init/preflight-off | launcher-vars | not attempted | none (empty) | — |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-BUNDLE-DELIVERY.md"

</details>

## The card

### LAUNCH-CARD-GROUND-RULES

[`agents/ground-rules.md`](../../../ground-rules.md) — the universal worker rules, one authored
source (FU-117) — is injected **verbatim** at the top of every card on every harness: a worker
clones only its project repo and goose loads no `CLAUDE.md`, so the card is the only channel
(`REPLAY:render_env_card`, :950–975). A missing, empty or unreadable file degrades loudly: the card
carries one line saying the block is unavailable this ride (a launcher-side gap, not the worker's)
and stderr carries a `WARN … env card degraded (FU-117)` line — never a silent drop. The file is read
at runtime from the launcher's own checkout; it is a member of this island and never moves.

**World:** `launcher-vars` with `GROUND_RULES_FILE` pointing at the row's file.

#### The ground-rules block

Legend: `file` = the state of the ground-rules file; `card_block?` = what the card carries in its
place.

| description | world | file | card_block? | stderr? |
|---|---|---|---|---|
| env-card-issue-context-gate | launcher-vars | present | the file's text verbatim | — |
| env-card-ground-rules/missing | launcher-vars | absent | `- WARN: the platform ground-rules block is unavailable this ride …` | `WARN: ground-rules file missing/empty/unreadable: <path> — env card degraded (FU-117)` |
| env-card-ground-rules/empty | launcher-vars | zero bytes | the same WARN line | the same |
| env-card-ground-rules/unreadable | launcher-vars | mode 000 | the same WARN line | the same |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-CARD-GROUND-RULES.md"

</details>

### LAUNCH-CARD-FACTS

After the ground rules, the card states this ride's facts, each computed from the knob that built
the ride and therefore true by construction (`render_env_card`, :976–1105). Card text is the rule
and the value the worker needs to act — no issue links, ids or dates (those stay in the clause's
comments). In order: the package proxies (with the enforcement state's consequence); context repos
(when `--context-repo` was passed); **Docker: YES** with the mirror recipe, or **Docker: NO**;
**Egress: ENFORCED (profile)** or **monitored, not blocked**; web research — claude's WebSearch, or
the platform search endpoint for the other harnesses; **Round r of N**; the write scope (`research/`
for a research recipe, else `fix/`); the base branch and "human-gated" when it is not master; the
parent Goal's `Goal` and `Acceptance` sections, quoted, for a goal child
([LAUNCH-PREFLIGHT-GOAL-BUDGET](dispatch.md#launch-preflight-goal-budget)); the issue-context line
(for an `issue-<N>` task with pre-flight on — never for a research task, which gets no bundle); one
line per declared image volume; the spec-process line
([LAUNCH-CARD-SPECS-PROCESS](#launch-card-specs-process)); and, when the claim declares an MCP
endpoint, the feedback tool with the launcher-stamped harness and model plus the image pin.

**World:** `launcher-vars` with the claim knobs as the row's input.

#### Which lines a ride's card carries

Legend: `knob` = the varied input; `card_line?` = the line it produces (abridged to its lead).

| description | world | knob | card_line? |
|---|---|---|---|
| env-card-docker-buildkit | launcher-vars | `fixer.docker: true` | `**Docker: YES.** …` incl. the BuildKit mirror-builder recipe |
| env-card-context-repos | launcher-vars | `--context-repo …/circles.git` | `**Context repos:** read-only reference clones at /work/context-repos/ (circles) …` |
| env-card-mcp-present | launcher-vars | `spec.mcp.endpoint` set, claude | `**Feedback tool: available** (harness: claude, model: …)` + `**Version skew:** …` |
| env-card-mcp-present/opencode | launcher-vars | `spec.mcp.endpoint` set, opencode | the same two lines, harness opencode |
| env-card-issue-context-gate | launcher-vars | `TASK=issue-1175` vs `TASK=research-…` | the issue-context line for the issue task only |
| env-card-machine-markers/env-card-machine-markers-capture | launcher-vars | — | no machine marker in the card's text |
| direct-child | homelab-278-tree | a goal child | `**This issue is one child of a GOAL.** …` + the quoted Goal + Acceptance |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-CARD-FACTS.md"

</details>

### LAUNCH-CARD-SPECS-PROCESS

When the repo's claim declares `specs: {root, tests, pin?}` (ADR-156) and the issue's declared
`Touches:` footprint reaches `<root>/**` or `<tests>/**` — by the scan's own footprint predicate
(`fp_conflict`), never a launcher regex — the ride gets the repo's pinned spec process mounted
read-only at `/mnt/snippets/process` as an image volume, and the card points at it (read
`briefs/author.md` first; list every spec change under `Spec changes:`, ⚖ on judgment rows)
(`REPLAY:specs-process-volume`, :1193–1243). The version is the one the repo's pin file names
(`SNIPPETS_WHEEL=…/releases/download/v<version>/…`, default `<root's parent>/scripts/lib/snippets.sh`)
at the ride's base; the image is `ghcr.io/teststuffstash/allure-behavior-snippets-process:v<version>`,
mounted by digest. A pin that cannot be read, or an image with no anonymously served manifest, makes
the state `unmounted`: the card says the process could not be mounted (launcher-side, not the
worker's) and still asks for the `Spec changes:` section — never silence. No `specs` field, or a
footprint that does not reach it: no line. A `specs` field outside the path grammar is ignored with a
WARN; a malformed `Touches:` block refuses ([LAUNCH-PREFLIGHT-BODY](dispatch.md#launch-preflight-body)).
The card's text is static — no version, no rule content: the mount speaks for itself.

**World:** `launcher-vars` with the claim's `specs` and the issue body as inputs (homelab#3030,
`gateway/specs` + `gateway/tests`, pin v0.6.5 in the `reached` row).

#### Mounted, unmounted, or nothing

Legend: `specs_field` = the claim's field; `touches` = whether the footprint reaches its roots;
`pin` = the pin file's state; `specs_process?` = the card's switch.

| description | world | specs_field | touches | pin | specs_process? |
|---|---|---|---|---|---|
| specs-process/reached | launcher-vars | `{root: gateway/specs, tests: gateway/tests}` | reaches | v0.6.5, image published | mounted |
| specs-process/not-reached | launcher-vars | the same | does not reach | — | "" (no line) |
| specs-process/field-absent | launcher-vars | absent | — | — | "" (no line) |
| specs-process/pin-missing ⚖ | launcher-vars | the same | reaches | no readable `SNIPPETS_WHEEL=` | unmounted |
| specs-process/pin-unpublished ⚖ | launcher-vars | the same | reaches | a version with no published image | unmounted |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "LAUNCH-CARD-SPECS-PROCESS.md"

</details>
