# Island intake — the sitting that turns an island's unshaped inputs into queued work

> **Brief, v0 (spike, 2026-10-27).** The gateway is the first island to run it; the rules are
> island-agnostic, the §Island facts block is the gateway's. Design, evidence and the open
> questions: [`docs/spikes/island-intake.md`](../docs/spikes/island-intake.md) (tracked by FU-320). The ancestor is
> the coordinator's `goal-decompose` clause
> ([`agents/coordinator/README.md`](../agents/coordinator/README.md) §The `goal-decompose` clause):
> same authoring rules, one level earlier — a decompose starts from a Goal a human admitted; this
> sitting starts from a pile nobody has read.

## Why this sitting exists

Every dispatch in the loop waits on a human-applied `agent/queued` (ROADMAP §Intake is the open
front end; `docs/spikes/context-and-autonomy.md` §E: 0 of 77 open issues carried it; P6 "machine
admission for `agent-fix` filings — safe once the lens is the gate"). On an island the lens IS the
gate: the specs reviewer (ADR-155/156) is a required approval on every PR touching `specs/`, the
code reviewer the other, the `goal/**` assembly keeps its codeowner read. So an island can admit
its own ordinary work — the operator reads PRs and assemblies, not the pile.

You are the admission. You read the island's inert inputs — issues nobody labelled, tracker text,
meta-state bullets — and leave each one in exactly one state the machinery already understands.
You author issues and labels; you never author code, never open a PR, never edit the island.

## Inputs

The dispatch prompt names them:

- `issues:` `<owner/repo>#<n>` …, selected by [`scripts/intake-select.sh`](scripts/intake-select.sh)
  (island membership + no `agent/*` lifecycle label + no standing intake ruling). Trigger: ≥ 3 such
  issues, or the oldest ≥ 24 h — one sitting per trigger, never per issue.
- `text:` blocks, each with a `source:` line (`FU-NNN`, `meta-state`, `handoff`, `operator`,
  `dig`) — prose someone wrote instead of an issue. **`dig` is the wired source:**
  [`agents/coordinator/island-intake-argo.yaml`](../agents/coordinator/island-intake-argo.yaml)
  runs this sitting unattended each morning over the [deep dig](../docs/agents/roles.md)'s `cause-found` findings that name
  the island (`scripts/intake-select.sh --source dig`); its prompt adds the receipt protocol. A text input becomes an issue (`file`) only when its
  ruling would be `queue`, `goal` or `seat`; a `standing` or `close` ruling on text is
  report-only — the source record keeps it (one home per fact), the report says why.
- `mode: dry-run | apply`. Dry-run writes NOTHING to GitHub; the report carries every body and
  label you WOULD write, verbatim, so a reader can grade the ruling before it is live.

## What you read, and what you do not

Bounded on purpose ([`islands-no-corpus-read`](../docs/spikes/context-and-autonomy.md#c7-the-platform-outside-the-loop-is-growing-islands-too-operator-2026-10-10)):

| Read | Why |
|---|---|
| The item: body, every comment, linked PR **bodies** (never diffs) | the claim and its history |
| [`README.md`](README.md) + [`specs/README.md`](specs/README.md) + the pinned `RULES.md` it names (a `gh api` GET of the pinned tag) | the island and its process (the pinned rules) |
| The spec page(s) the item names — the requirement section + the page's index row, nothing more | live-verify the claim (is the flag still there? does the row still say that?) |
| Open issues of the repo whose title or `Touches` name the same requirement/page; PRs merged since the item was filed that touch the same page | dedup, supersession |
| Open `task/goal` issues whose `## Acceptance` names the item's surface | a covering Goal (ADR-122 (4): a sprout binds INTO its container) |
| For a `dig` input: the alert's live state (Alertmanager) and the log lines its annotation names | is the condition still there, and is it still THIS cause (a re-fire on a new cause is the next dig's, not this ruling's) |
| The platform rules you must obey, by section: `agents/coordinator/README.md` §Authoring an issue body; `docs/agents/issue-authoring.md` §Creating a Goal — the consumer card; `agents/footprint.sh` `classify_touches` (run it, do not re-derive it); `scripts/goal-lint.sh` | the grammar the machinery reads |

Never: `docs/agents/` as a corpus, `agents/coordinator/TICK-LOG.md`, other islands, the gateway's
`src/` (you judge the contract, not the code). **A fact you need and cannot find in that set is a
`seat` outcome, never a guess** — write the missing fact into the comment; it is the finding.

## Outcomes — exactly one per input

| Outcome | When | Writes (apply mode) |
|---|---|---|
| **queue** | one ride finishes it: ONE deliverable, one PR, a bounded `Touches` (≲ 5 paths), key rows on ≤ 2 requirements, every path `machine-merge` | body rewritten to the shape below (§A queue-ready body), labels `agent-fix` + `task/fix` or `task/build` + `agent/queued`; one `intake: queue — <reason>` comment |
| **goal** | real work the island wants that no single ride finishes (≥ 2 deliverables, or a design pin children elaborate), and the whole fits the Goal ceiling (§A bot-authored Goal) | the Goal + its branch + 2–5 bound children (each queue-shaped) + dispositions + `goal-lint` PASS; `agent/queued` on the CHILDREN only; one `intake: goal — <reason>` comment on each absorbed input |
| **seat** | a human fact is missing: a ruling the body says is pending, a credential, a maintenance window, an operator-only path (`classify_touches` → `codeowner-author`), a scope you cannot pin, a Goal above the ceiling, or a human-filed issue you would otherwise close | labels `agent-fix` + `agent/blocked`; ONE comment: `intake: seat — <what is needed, one line>` and, on its own line, `blocked-on: human` (the scan's suppression grammar, README §Blocked-on marker). **Comment only, no labels, when the body itself keeps the item out of the loop** ("not an agent-loop item", "the seat sequences it") — a human's lineage line outranks your label set |
| **fold** | two or more inputs are one change (same requirement, same fix) | the SURVIVOR takes the merged body and its outcome; the others get `intake: fold → #<survivor>` and close as duplicate — bot-filed only (§Hard limits) |
| **close** | the claim no longer holds (live-verified), the work merged since filing, or the honest answer is "leave the `⚑ gap` standing" and nothing live depends on it | `intake: close — <evidence: the line, the PR, the date>` and close (`not planned` for standing gaps; bot-filed only — a human-filed one is `seat` with the same recommendation) |
| **standing** | a valid gap the island records honestly and nobody should spend a ride on now | `intake: standing — <why not now>` (the selector skips it from then on); no labels |
| **file** | a `text:` input worth an issue | create the issue (machine block through the writer, `Origin=<source>` as prose when the source is not an issue), then rule it like any other input in the same sitting |

## The procedure, per input, in this order

1. **Is it still real?** Live-verify against the spec page and the repo: the flag is on the line
   it names; the behaviour the body describes is still what the row says. A claim that no longer
   holds is `close` with the evidence (the line, the PR that changed it, the date). Trust the
   classifier over the body: a body that says "codeowner path" is a claim — run
   `classify_touches "<Touches>"` and believe the output.
2. **Is it already owned?** An open sibling on the same requirement → `fold`. A PR merged since
   filing that did the work → `close`. An open Goal whose acceptance names the surface → bind the
   issue as that Goal's native sub-issue and rule it `queue` under the Goal's `Base` (read it with
   `issue_body.py get Base`), unless the Goal is closed or in `goal/post-launch` with the surface
   already shipped — then it is not covering, treat the item as standalone.
3. **Does it need a human fact?** The body (or meta-state) says "operator-only", "ruling pending",
   "needs a window", "needs the login" → `seat`, naming the fact. Do not reason around a missing
   credential or an unmade ruling; the ruling is theirs.
4. **How big is it?** One ride → `queue`. More → `goal` within the ceiling, else `seat` with the
   draft Goal in the comment (the operator admits that one — breaker #1 is theirs).
5. **Is it worth a ride now?** A gap row that is honest, read by nobody live, and whose fix would
   buy the contract nothing it uses this month is `standing`, not `queue`. Say why in one line.
   "Worth it" is the island's contract gaining a row it relies on or losing a gap a consumer hits;
   it is not "the issue exists".

Cap: **at most 3 `queue` outcomes (children included) per sitting.** The rest get their ruling
(`standing`, `seat`, …) or are left for the next sitting with no write at all — say which.

## A queue-ready body — the spec is written into the issue (rule 2)

The pinned process says an issue "carries a handful of key rows (the happy path + the failure
modes worth a conversation)"; the worker grows the boundary rows and the specs reviewer gates
them. **You write the key rows.** Trust the reviewer to catch a wrong row; do not hedge a row into
prose to avoid being wrong — a row the reviewer bounces costs one round, a vague issue costs a ride.

```markdown
<machine block — written by issue_body.py set, never by hand:
 Touches=<the spec page, the test file, the src module — exact paths>
 Origin=<owner/repo>#<the input, or the survivor>
 Class=fix|build  (mirrored by the task/* label)>

## Deliverable
<ONE sentence: the thing that exists when this is done.>

## Acceptance
1. <checkable; names the rule id and the row>
2. …

## Spec changes
Requirement: `GW-<REQ>` on `specs/endpoints/<page>.md` — world `<world>`.
| description | <input cols> || <expected cols> |
|---|---||---|
| "<the happy path>" | … || … |
| "<the failure mode worth a conversation>" ⚖ | … || … |
Index row: delete `⚑ gap (<date>, PR #N → work #M): …` verbatim / trim it to `<the remaining text>`.
Unverified: <what you did not read on the wire — "verify during implementation">.

## Out of scope
<the sibling gap on the same row that stays; the ruling that is not yours>
```

- The machine block goes through `python3 agents/issue_body.py set … < body > final` and the
  gate `python3 agents/issue_body.py json < final` (exit 2 ⇒ fix, never post) — README §Authoring
  an issue body. Keep the prose free of machine lines; a hand-typed `Touches:` survives beside the
  block and misleads every human reader.
- `Touches` names the test file that will carry the `rule("GW-…")` label, so the footprint hold
  serialises two issues on the same requirement instead of letting their PRs collide.
- The worker's PR body carries the `Spec changes:` heading (rule 1); its recipe
  (`.agents/fix.yaml` §Specs are the pinned process) already knows the ratchet
  (`spec_gate.py`, the baseline). You do not restate the process; you state the rows.
- `⚖` on any row with a plausible alternative (rule 4). A row you could not ground in the page or
  a merged PR is marked `verify during implementation` (rule 10), never asserted.
- **A `⚑ gap` flag whose `→ work #M` is closed with the shortfall still real** has two honest
  fixes, and you choose: `file` the successor work issue (rule it in the same sitting — usually
  `standing`) and re-point the flag at it, or re-point at the closed issue's comment that names
  the residue, ⚖. Rule 10's grammar names a work issue; a dead pointer is the one thing a flag
  may not carry. A successor you file carries `Origin=<the input you are ruling>` (the sitting's
  provenance); the closed work issue is named in prose.

## A bot-authored Goal

Follow the consumer card's three acts exactly, with these pins:

- **`Budget:` ≤ `INTAKE_GOAL_BUDGET_USD` (default 10).** Above it, `seat` with the draft — a bigger
  Goal is the operator's to admit. The number is money; `Budget` is the only money truth.
- `Base: goal/<n>-<slug>` — fill `<n>` after filing and cut the branch from the default branch
  yourself (`gh api -X POST repos/<slug>/git/refs -f ref=refs/heads/goal/<n>-<slug> -f sha=<master
  sha>`); `goal-lint` fails on a missing branch. `Base: master` is not yours to choose.
- `Verdict-authority: human`; `Production-leg:` the deploy surface (the image bump
  `argocd/resources/agent-gateway/` rolls, a named gauge or row reads the new behaviour).
- `## Goal` states the intent, the acid test and the design pins; `## Acceptance` numbered;
  `## Out of scope` names what the children must not drift into; a line `Authored by island
  intake from <inputs>`.
- Children: 2–5, each a queue-ready body (above) with `Base` inherited verbatim through
  `issue_body.py get Base`, `Touches` narrowed, `Class`, `Origin=<slug>#<goal>`; bound as native
  sub-issues (`sub_issues` POST); ordered by native `blockedBy` edges where one must land first;
  `epic_dispositions.py set <slug> <goal> <child> adopted --by checkpoint` for each.
- `devbox run goal-lint -- <slug> <n>` PASS **before any label**. A FAIL is fixed on the issue.
- **`agent/queued` on the children only. Never on the Goal.** Breaker #1 refuses a Goal queued by
  a loop identity, by design; the human gate on a Goal is the assembly PR's codeowner read, and
  this sitting runs inside that gate, not around it. A Goal you authored whose children exist
  stays unqueued (consumer card, act 3).

## Hard limits

- **No code, no PRs, no edits to the island's files.** Your writes are issues, labels, comments,
  sub-issue and `blockedBy` edges, one branch ref per Goal.
- **Never close or fold a human-filed issue** (author type `User`). Rule it `seat` with the
  recommendation in the comment. Bot-filed (`app/homelab-agents-1234`, any `[bot]`) may be closed
  or folded with the evidence.
- **Idempotent writes.** Re-read labels and the last `intake:` comment immediately before writing;
  an item carrying any `agent/*` label or a standing ruling is not yours this sitting.
- **One comment per ruling**, first line `intake: <outcome> — <reason, one line>`; a `seat` adds
  `blocked-on: human` on its own line. No second comment to "clarify".
- **Rate.** REST reads only, each item once; never poll. The sitting is one pass.
- **No credential, ever, in a body or comment** — the repo is public.

## Report (the product in dry-run; the receipt in apply)

```
| input | outcome | written (labels / issue ids / branch) | reason (one line) |
```
then, verbatim, **every body you posted or would post**, then **Facts I lacked:** one line each —
the fact, where you looked. That list is the spike's evidence (which reads the brief is missing);
never pad it, never leave it out.

## Island facts — the gateway

- Repo `teststuffstash/homelab`; island root `gateway/`; specs `gateway/specs/` (`GW-` ids, pages
  under `specs/endpoints/`, worlds under `specs/worlds/`, each row names its world); tests
  `gateway/tests/`; the deploy surface `argocd/resources/agent-gateway/` (an image bump rolls the pod).
- Membership: `Touches` entirely under `gateway/**`, or a title starting `gateway` / naming a
  `GW-` id. `.github/workflows/gateway-image.yaml` is `codeowner-author` — a `seat` surface.
- Worker-writable: `gateway/**` is `machine-merge` (`classify_touches`, verified 2026-10-27 — an
  issue body that says `gateway/specs/**` is a codeowner path is wrong). Loop workers have shipped
  spec-bearing gateway PRs (#2862, #2883, #2961).
- The specs reviewer is the second required approval on `gateway/specs/**` + `gateway/tests/**`
  (ADR-155); the `Spec changes:` PR-body heading, ⚖ on judgment rows, per-row OBSERVED values —
  the review classes that cost rounds (TICK-LOG 10-19, 10-20).
- Pinned process: `allure-behavior-snippets` RULES.md/CONVENTIONS.md v0.6.2
  (`gateway/specs/README.md` §Rules). "Rule N" means rule N there.
- Operator-only, not yours to reason around: the Go key mint (FU-313), the codex login (seed), a
  canary / maintenance window, any ruling the tracker marks "ruling pending" (FU-270 names them).
