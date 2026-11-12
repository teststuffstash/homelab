# Island intake — the sitting that turns an island's unshaped inputs into queued work

> **Brief, v0 (spike, 2026-10-27).** The gateway is the first island to run it. **The rules here
> are island-agnostic and live only here;** the §Island facts block at the end is the gateway's,
> every other PLATFORM island's lives in [`docs/intake/<island>.md`](../docs/intake/), and a STACK
> island's lives in its own repo (ADR-160) —
> [agent-loop](../docs/intake/agent-loop.md), [substrate](../docs/intake/substrate.md),
> [dependency-upgrades](../docs/intake/dependency-upgrades.md), [mgmt-box](../docs/intake/mgmt-box.md),
> [router-pair](../docs/intake/router-pair.md). A sitting for another island reads this brief, then
> that file IN PLACE OF §Island facts and the gateway rows of §What you read (`README.md`,
> `specs/`, `src/`); membership is `intake-select.sh --island <island>`. Design, evidence and the open
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
  issues, or the oldest ≥ 24 h — one sitting per trigger, never per issue. **Attribution inputs**
  (`kind: attribution` — the agent-loop sitting's only): bot-filed (§Hard limits) issues no island
  claims, because the loop's filers leave component attribution to intake. The first act on one is
  naming its island(s) (step 0 of §The procedure).
- `text:` blocks, each with a `source:` line (`FU-NNN`, `meta-state`, `handoff`, `operator`,
  `dig`) — prose someone wrote instead of an issue. **`dig` is the wired source:**
  [`agents/coordinator/island-intake-argo.yaml`](../agents/coordinator/island-intake-argo.yaml)
  runs this sitting unattended each morning over the [deep dig](../docs/agents/roles.md)'s `cause-found` findings on
  the island's alerts (`scripts/intake-select.sh --source dig`); its prompt adds the receipt protocol. A text input becomes an issue (`file`) only when its
  ruling would be `queue`, `goal` or `seat`; a `standing` or `close` ruling on text is
  report-only — the source record keeps it (one home per fact), the report says why.
- `reread:` `<owner/repo>#<n>` … — island issues that an earlier ruling left waiting on a human
  (`agent/blocked`, or a standing `intake: seat`) for `INTAKE_REREAD_AGE_D` days or more
  (`scripts/intake-select.sh --source pile`). A wait is a claim about ONE fact; facts move. You
  re-verify that fact (§The procedure, step R) and either change the ruling or leave the item
  untouched — a re-read that changes nothing writes nothing. The morning sitting gets these
  together with its `dig` inputs and the island's unruled `issues:`; there an unchanged wait is
  the receipt line `unchanged`, which keeps it from being re-read for `INTAKE_REREAD_EVERY_D` days.
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
| The alert's live state (Alertmanager `/api/v2/alerts`) and the gauge it reads (Prometheus `/api/v1/query`), for any input that names an alert or a metric; for a `dig` input also the log lines its annotation names | is the condition still there, since when, and is it still THIS cause (a re-fire on a new cause is the next dig's, not this ruling's) |
| The ride record of an issue a worker touched: `s3://agent-transcripts/homelab/issue-<n>/<run>/run.log` + `manifest.json` (the run log's tail carries the worker's structured report). The session `.jsonl` only when the run log does not answer the question | what the ride built, what stopped it, which branch holds the work |
| Loop-worker PRs on the island merged since a block was written (author `app/homelab-agents-1234`, bodies only) | is the blocker a fact about the island, or about that one ride |
| The gateway's own read-only views: `GET /healthz`, `/catalog/opencode`, `/catalog/openrouter`, `/sessions?task=<task>` on `agent-gateway.agent-egress.svc:8080`; the deployed `policy.json` and `benchmarks.json` under `argocd/resources/agent-gateway/` | live-verify a claim about the catalog, the store, a session's outcome; test a `standing` ruling's own trigger |
| The platform rules you must obey, by section: `agents/coordinator/README.md` §Authoring an issue body; `docs/agents/issue-authoring.md` §Creating a Goal — the consumer card; `agents/footprint.sh` `classify_touches` (run it, do not re-derive it); `scripts/goal-lint.sh` | the grammar the machinery reads |

Every live read is a GET. A probe that errors is not an empty answer: say which read failed and
rule on what you have, or `seat` naming it. Never: `docs/agents/` as a corpus, `agents/coordinator/TICK-LOG.md`, other islands, the gateway's
`src/` (you judge the contract, not the code). **A fact you need and cannot find in that set is a
`seat` outcome, never a guess** — write the missing fact into the comment; it is the finding.

## Outcomes — exactly one per input

| Outcome | When | Writes (apply mode) |
|---|---|---|
| **queue** | one ride finishes it: ONE deliverable, one PR, a bounded `Touches` (≲ 5 paths), key rows on ≤ 2 requirements, every path `machine-merge` | body rewritten to the shape below (§A queue-ready body), labels `agent-fix` + `task/fix` or `task/build` + `agent/queued`; one `intake: queue — <reason>` comment |
| **goal** | real work the island wants that no single ride finishes (≥ 2 deliverables, or a design pin children elaborate), and the whole fits the Goal ceiling (§A bot-authored Goal) | the Goal + its branch + 2–5 bound children (each queue-shaped) + dispositions + `goal-lint` PASS; `agent/queued` on the CHILDREN only; one `intake: goal — <reason>` comment on each absorbed input |
| **seat** | a human fact is missing: a ruling the body says is pending, a credential, a maintenance window, an operator-only path (`classify_touches` → `codeowner-author`), a scope you cannot pin, or a Goal above the ceiling | labels `agent-fix` + `agent/blocked`; ONE comment: `intake: seat — <what is needed, one line>` and, on its own line, `blocked-on: human` (the scan's suppression grammar, README §Blocked-on marker). **Comment only, no labels, when the body itself keeps the item out of the loop** ("not an agent-loop item", "the seat sequences it") — a human's lineage line outranks your label set |
| **fold** | two or more inputs are one change (same requirement, same fix) | the SURVIVOR takes the merged body and its outcome; the others get `intake: fold → #<survivor>` and close as duplicate (§Hard limits — whose issue it is) |
| **close** | the claim no longer holds (live-verified), the work merged since filing, or the honest answer is "leave the `⚑ gap` standing" and nothing live depends on it | `intake: close — <evidence: the line, the PR, the date>` and close (`not planned` for standing gaps; §Hard limits — whose issue it is) |
| **requeue** | a `reread:` input whose blocker no longer holds and whose work is one ride from done (a salvaged branch, a blocker that was that ride's own) | labels: remove `agent/blocked`, add `agent/queued`; `intake: requeue — <the fact that changed, with its evidence>`, naming the resumable branch when the ride record has one (the next round resumes it) |
| **standing** | a valid gap the island records honestly and nobody should spend a ride on now | `intake: standing — <why not now>` (the selector skips it from then on); no labels |
| **split** | one input carries deliverables owned by two or more islands (typically an attribution input) | `file` one issue per island-owned part — its body names the island, narrows `Touches` to that island's paths, `Origin=<the input>`; one `intake: split → #a, #b` comment on the input, then close it (§Hard limits — whose issue it is). A part owned by ANOTHER island is filed and left for that island's sitting (no labels, no ruling); a part owned by yours is ruled in this sitting like any other input |
| **file** | a `text:` input worth an issue, or the parity gap inside a `seat` (§The procedure, step 3; `Origin=<the input>`) | create the issue (machine block through the writer, `Origin=<source>` as prose when the source is not an issue), then rule it like any other input in the same sitting |

## The procedure, per input, in this order

0. **Whose is it?** (attribution inputs only.) Name the island(s) that own its deliverables, from
   the facts files' membership lines. All yours → continue as a member. All one OTHER island's →
   `split` with one part (re-filed under that island's title/`Touches`, so its selector claims it).
   Two or more islands → `split`. No island owns a part → that part is `seat`, naming the missing
   owner. You never rule another island's part — its sitting does.
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
   **Before `seat`, the parity check.** Ask what the wait is made of. When part of it is a fact
   the island already reads for a sibling (§Island facts names the sibling sets) through a
   facility this member lacks — a view, a read leg, a gauge that at least two siblings have under
   the same page — the facility is a gap the contract already implies, not a feature you invent.
   `file` it as its own issue, the siblings' requirement as the template for its key rows (⚖
   where this member differs), and rule it in this sitting like any other input. The original
   keeps `seat` for what remains, its comment naming the filed issue next to the missing fact.
   Parity fills what siblings already have: it never carries the ruling the item waits on, and
   a facility no sibling has is a new feature — `seat`. The filed part and its origin are
   disjoint by construction: step 2 never folds one into the other, and a later re-rule of the
   origin treats its named parity issue as already filed — no fold, no second filing. A facts
   file that declares no sibling set has no parity check.
4. **How big is it?** One ride → `queue`. More → `goal` within the ceiling, else `seat` with the
   draft Goal in the comment (the operator admits that one — breaker #1 is theirs).
5. **Is it worth a ride now?** A gap row that is honest, read by nobody live, and whose fix would
   buy the contract nothing it uses this month is `standing`, not `queue`. Say why in one line.
   "Worth it" is the island's contract gaining a row it relies on or losing a gap a consumer hits;
   it is not "the issue exists".

**R. A `reread:` input — is the wait still true?** Read the comment that parked it and name the
ONE fact it waits on. Then test that fact, not the comment: the ride record (did the work finish?
what stopped it?), the loop-worker PRs merged since (was the blocker that ride's own?), the alert
or gauge, the spec line, the ruling the tracker called pending, the done-when the body offers
(has one of them already happened?). Changed → rule the item afresh through steps 1–5 (`requeue`,
`queue` after a rewrite, `close`, `standing`). Unchanged → no write; the report says which fact
you tested and where. Never restate a wait in a second comment. Step 3's parity check runs on a
re-read too: a wait that narrows (one of its facts filed as a parity gap) has changed, and gets
the one comment naming what remains.

Cap: **at most 3 `queue` outcomes (children and `requeue` included) per sitting.** The cap limits `queue`, not
ruling: rule EVERY input. Only an input whose ruling would be `queue` and arrives over the cap is
left for the next sitting with no write at all (the selector re-offers it) — the report lists it as
`deferred (cap)`.

## A queue-ready body — the spec is written into the issue (rule 2)

The pinned process says an issue "carries a handful of key rows (the happy path + the failure
modes worth a conversation)"; the worker grows the boundary rows and the specs reviewer gates
them. **You write the key rows.** Trust the reviewer to catch a wrong row; do not hedge a row into
prose to avoid being wrong — a row the reviewer bounces costs one round, a vague issue costs a ride.

```markdown
<machine block — written by issue_body.py set, never by hand:
 Touches=<the spec page, the test file, the src module — exact paths>
 Origin=<kept verbatim when the input already has one; else owner/repo#<the input, or the survivor>>
 Class=fix|build  (mirrored by the task/* label)>

## Deliverable
<ONE sentence: the thing that exists when this is done.>

## Acceptance
1. <checkable; names the rule id and the row>
2. …

## Spec changes   ← on an island without specs/: `## Key rows`, the rows its facts file names
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
  (`spec-join-ratchet.py` + `spec-hygiene-ratchet.py`, their baselines). You do not restate the process; you state the rows.
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
- **Whose issue it is, and how old (ADR-163).** A bot-filed issue (`app/homelab-agents-1234`, any
  `[bot]`) may be closed, folded, split or rewritten with the evidence. An issue under the
  OPERATOR's login is almost always a jail session's text and is rulable the same way, weighted
  by age: the older and staler it is (the claim moved, the work merged, the done-when happened),
  the freer your hand — close it or rewrite it on the evidence; a recent one gets light editing
  only (the machine block, the key rows, a narrowed `Touches`) — its intent stays as written, and
  when you would close a recent one, rule it `seat` with the recommendation instead. Every close
  or rewrite of an operator-login issue keeps the original body recoverable (the comment quotes
  what was removed or says "rewritten; the original is in the edit history") so one push undoes
  it. Any other human's issue is never closed, folded or rewritten: `seat`.
- **Idempotent writes.** Re-read labels and the last `intake:` comment immediately before writing;
  an item carrying any `agent/*` label or a standing ruling is not yours this sitting — unless it
  came as a `reread:` input, where `agent/blocked` or the `seat` ruling is exactly what you test.
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
- Pinned process: `allure-behavior-snippets` RULES.md/CONVENTIONS.md, at the version
  `gateway/specs/README.md` §Rules pins (no number here — it drifted). "Rule N" means rule N there.
- Sibling sets (step 3's parity check): the rails — `opencode`, `openrouter`, `anthropic`,
  `codex`. A per-rail facility is a `/catalog/<rail>` view, a catalog read leg, a headroom
  reading, a metric family.
- A seat act, not the operator's: a recorded wire answer read through the pod's existing
  credential (a fixture under `gateway/tests/fixtures/`). A `seat` waiting only on one says
  "seat act" in its comment, so the seat does it without the operator.
- Operator-only, not yours to reason around: the Go key mint (FU-313), the codex login (seed), a
  canary / maintenance window, any ruling the tracker marks "ruling pending" (FU-270 names them).
