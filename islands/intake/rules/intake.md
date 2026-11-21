# Island intake — the sitting that turns an island's unshaped inputs into queued work

> **Brief, v0 (spike, 2026-10-27).** **The rules here are island-agnostic and live only here;**
> an island's facts live in its facts file: a PLATFORM island's is
> [`docs/intake/<island>.md`](../../../docs/intake/), a STACK island's lives in its own repo
> (ADR-160) —
> [gateway](../../../docs/intake/gateway.md), [agent-loop](../../../docs/intake/agent-loop.md), [substrate](../../../docs/intake/substrate.md),
> [dependency-upgrades](../../../docs/intake/dependency-upgrades.md), [mgmt-box](../../../docs/intake/mgmt-box.md),
> [router-pair](../../../docs/intake/router-pair.md), [scan](../../../docs/intake/scan.md), [launch](../../../docs/intake/launch.md), [retro](../../../docs/intake/retro.md). A sitting reads this brief, then
> its island's facts file (§Island facts); membership is `intake-select.sh --island <island>`. Design, evidence and the open
> questions: [`docs/spikes/island-intake.md`](../../../docs/spikes/island-intake.md) (tracked by FU-320). The ancestor is
> the coordinator's `goal-decompose` clause
> ([`agents/coordinator/README.md`](../../../agents/coordinator/README.md) §The `goal-decompose` clause):
> same authoring rules, one level earlier — a decompose starts from a Goal a human admitted; this
> sitting starts from a pile nobody has read.

## Why this sitting exists

Every dispatch in the loop waits on a human-applied `agent/queued` (ROADMAP §Intake is the open
front end; P6 "machine admission … safe once the lens is the gate"). On an island the lens IS the
gate: the specs reviewer (ADR-155/156) is a required approval on every PR touching `specs/`, the
code reviewer the other, and a Goal keeps its human verdict (`Verdict-authority: human`); an
assembly keeps a codeowner read only where its paths have an owner (§Island facts says). So an
island can admit its own work — the operator reads verdicts, not the pile.

You are the admission. You read the island's inert inputs — issues nobody labelled, tracker text,
meta-state bullets — and leave each one in exactly one state the machinery already understands.
You author issues and labels; you never author code, never open a PR, never edit the island.

## Inputs

The dispatch prompt names them:

- `issues:` `<owner/repo>#<n>` …, selected by [`scripts/intake-select.sh`](../scripts/intake-select.sh)
  (island membership + no `agent/*` lifecycle label + no earlier `intake:` outcome). Trigger: ≥ 3 such
  issues, or the oldest ≥ 24 h — one sitting per trigger, never per issue. Membership is the
  FILER's naming (a title cue, or its `Touches`) — a hint: step 0 tests it. A row
  carrying `forwards: <n>` reached you by `n` earlier `forward` outcomes (another island's sitting
  named yours). **Attribution inputs**
  (`kind: attribution` — the agent-loop sitting's only): bot-filed (§Hard limits) issues no island
  claims, because the loop's filers leave component attribution to intake. The first act on one is
  naming its island(s) (step 0 of §The procedure).
- `text:` blocks, each with a `source:` line (`FU-NNN`, `meta-state`, `handoff`, `operator`,
  `dig`) — prose someone wrote instead of an issue. **`dig` is the wired source:**
  [`agents/coordinator/island-intake-argo.yaml`](../../../agents/coordinator/island-intake-argo.yaml)
  runs this sitting unattended each morning over the [deep dig](../../../docs/agents/roles.md)'s `cause-found` findings on
  the island's alerts (`scripts/intake-select.sh --source dig`); its prompt adds the receipt protocol. A text input becomes an issue (`file`) only when its
  outcome would be `queue`, `goal` or `seat`; a `standing` or `close` on text is
  report-only — the source record keeps it (one home per fact), the report says why.
  **`responder`** rides the same run: ONE input per recurring class of report-only responder
  triages — same alert, same namespace, on the island's subjects, at least `INTAKE_RESPONDER_MIN`
  in the dig's lookback — listing every member finding (`--source dig`, the selector's header).
  Each member's `remediation_would` is an untested proposal for one instance: decide the class on
  its cause, never by applying an instance's act (ADR-148).
- `reread:` `<owner/repo>#<n>` … — island issues that an earlier outcome left waiting on the operator
  (`agent/blocked`, or a standing `intake: seat`) for `INTAKE_REREAD_AGE_D` days or more
  (`scripts/intake-select.sh --source pile`). A row with `wait: pr-hold` is an issue the loop still
  holds whose open PR (`pr`) carries `blocked-on: human` as its newest marker: the wait was
  written on the PR, by a PR lane, and no label shows it (offered only under `INTAKE_PR_HOLDS=1`). A wait is a claim about ONE fact; step R
  re-tests it, and a re-read that changes nothing writes nothing. The morning sitting gets these
  together with its `dig` inputs and the island's undecided `issues:`; there an unchanged wait is
  the receipt line `unchanged`, which keeps it from being re-read for `INTAKE_REREAD_EVERY_D` days.
- `gap:` `<specs page>#<REQ>` … — `⚑ gap` / `🚧 WIP` rows of the island's own specs that the
  selector offers. Each is decided like a `text:` input whose source is the spec row: it becomes an
  issue (`file`) only when its outcome would be `queue`, `goal` or `seat`; `standing` or `close` is
  report-only — the row keeps its flag.
- `escape:` `<owner/repo>#<pr>` … — PRs of issues this island's intake queued that drew
  CHANGES_REQUESTED. Not decided through the outcome table: read through step E (§The procedure),
  their product is records, and a `file` when a class repeats. `escape-prior:` lines, when the
  prompt carries them, are earlier sittings' records (from their receipts) — read, never re-classified.
- `wait:` `<owner/repo>#<n>@<parked_at>/<released|standing>` … — one parking comment each (a
  `blocked-on: human`, or a `seat` with no marker) on an island item: released since, or standing
  after a re-read left it `unchanged` (`scripts/intake-select.sh --source wait`). Not ruled through
  the outcome table: read through step W, their product is records. The same source adds `reread:`
  rows carrying `stale` — a wait whose named target closed or merged — which step R re-reads at once.
- `mode: dry-run | apply`. Dry-run writes NOTHING to GitHub; the report carries every body and
  label you WOULD write, verbatim, so a reader can grade the outcome before it is live.

## What you read, and what you do not

Bounded on purpose ([`islands-no-corpus-read`](../../../docs/spikes/context-and-autonomy.md#c7-the-platform-outside-the-loop-is-growing-islands-too-operator-2026-10-10)):

| Read | Why |
|---|---|
| The item: body, every comment, linked PR **bodies** (never diffs) | the claim and its history |
| Open issues of the repo whose title or `Touches` name the same requirement/page; PRs merged since the item was filed that touch the same page | dedup, supersession |
| Open `task/goal` issues whose `## Acceptance` names the item's surface | a covering Goal (ADR-122 (4): a sprout binds INTO its container) |
| The alert's live state (Alertmanager `/api/v2/alerts`) and the gauge it reads (Prometheus `/api/v1/query`), for any input that names an alert or a metric; for a `dig` input also the log lines its annotation names | is the condition still there, since when, and is it still THIS cause (a re-fire on a new cause is the next dig's, not this outcome's) |
| The ride record of an issue a worker touched: `s3://agent-transcripts/homelab/issue-<n>/<run>/run.log` + `manifest.json` (the run log's tail carries the worker's structured report). The session `.jsonl` only when the run log does not answer the question | what the ride built, what stopped it, which branch holds the work |
| Loop-worker PRs on the island merged since a block was written (author `app/homelab-agents-1234`, bodies only) | is the blocker a fact about the island, or about that one ride |
| What the ride can do: the facts file's `## What a ride can do` — the recipe that rides the island and what it refuses, the write tier of its paths, the gates its PR runs, what the pod reaches and what it does not | before a `queue` or `goal` body is written: a body never asks a ride for an edit its recipe bans or a read its pod cannot make |
| For an `escape:` input: the PR's body, reviews, review comments and issue comments, its file names (a hunk only when a finding cannot be classified without it), and the spec section it touches at the PR's base sha | step E — what the reviewers found that the body could have prevented |
| For a `wait:` input: the item's comments (its events when they show the release), and the lines the wait cites at the default-branch commit before its parking comment | step W — whether the rules made the wait necessary |
| The platform rules you must obey, by section: `agents/coordinator/README.md` §Authoring an issue body; `docs/agents/issue-authoring.md` §Creating a Goal — the consumer card; `agents/footprint.sh` `classify_touches` (run it, do not re-derive it); `scripts/goal-lint.sh` | the grammar the machinery reads |

These rows are the ones every island shares. The island's own reads are the rows under
`## Sources` in its facts file (§Island facts) — a table `question | read | note`: which read
answers which kind of question (where a limit is declared, its live value, the alert rule file,
the ledger), each a command to run as written. They are part of this table. A row whose note
says `seat-only` is a read your identity cannot make: what it would answer is `deferred (fact)`
or `Unverified`, never guessed.

Every live read is a GET. A probe that errors is not an empty answer: say which read failed and
decide on what you have. Never: `docs/agents/` as a corpus, `agents/coordinator/TICK-LOG.md`, other islands, and what
the facts file's `## Sources` rules out. **A fact you need and cannot find in that set is
never a guess.** There are two kinds:
- **A fact the decision stands on** — which means fixes it, how large, whether it fits, whether
  the fix is possible at all. You establish it before a body is written, with the narrowest GET
  that answers it (a cluster read, a Prometheus query, the one ledger or doc section that holds
  it) — outside the table when it has to be, but never from the Never list above. A read made
  outside the facts file's `## Sources` is reported under **Facts I lacked** with the exact
  command, and a facts-file row for it is the sitting's own edit proposal (the row as it would
  read, under the same line; a record, not a write). A deciding fact you cannot read leaves the input with no write:
  the report lists it `deferred (fact)` with the fact and where it lives (receipt line
  `deferred`). It is never handed to the worker.
- **Any other fact** goes under `Unverified` and into **Facts I lacked** (step 3), never a wider
  read.

**Gathering is a subagent's job when it is more than a few reads.** A deciding fact that takes a
survey (several objects, a ledger plus the live thing, a sibling's history) goes to a subagent of
this sitting — your own Agent tool, no model override, read-only — briefed with the one question,
where the answer lives, and the shape to return it in (the numbers and their sources, no
recommendation). You decide on what it returns and cite it in the body. Never `file` a research
issue, and never queue a ride, for a fact a subagent can read in this sitting.

## Outcomes — exactly one per input

| Outcome | When | Writes (apply mode) |
|---|---|---|
| **queue** | one ride finishes it: ONE deliverable, one PR, a bounded `Touches` (≲ 5 paths — paths the island's facts file adds to every issue, its bookkeeping files, do not count), key rows on ≤ 2 requirements, every path `machine-merge` | body rewritten to the shape below (§A queue-ready body); then §Review and repair; then labels `agent-fix` + `task/fix` or `task/build` + `agent/queued` (+ `experiment/open` when the body carries a block — §Experiment); one `intake: queue — <reason>` comment |
| **goal** | real work the island wants that no single ride finishes (≥ 2 deliverables, or a design pin children elaborate), and the whole fits the Goal ceiling (§A bot-authored Goal) | the Goal + its branch + 2–5 bound children (each queue-shaped) + dispositions + `goal-lint` PASS; then §Review and repair; then `agent/queued` on the CHILDREN only (+ `experiment/open` on a child that carries a block — §Experiment); one `intake: goal — <reason>` comment on each absorbed input |
| **seat** (the operator) | an entry of step 3's closed list holds — or the item waits only on an open issue or PR (step 3) | labels `agent-fix` + `agent/blocked`; ONE comment: `intake: seat — <the entry: the one fact needed>` and, on its own line, `blocked-on: human` — or `blocked-on: issue=<n>` / `pr=<n>` when no entry holds and the wait is that item (the scan's suppression grammar, README §Blocked-on marker). **Comment only, no labels, when the body itself keeps the item out of the loop** ("not an agent-loop item", "the seat sequences it") — a human's lineage line outranks your label set |
| **fold** | two or more inputs are one change (same requirement, same fix) | the SURVIVOR takes the merged body and its outcome; the others get `intake: fold → #<survivor>` and close as duplicate (§Hard limits — whose issue it is) |
| **close** | the claim no longer holds (live-verified), the work merged since filing, or the honest answer is "leave the `⚑ gap` standing" and nothing live depends on it | `intake: close — <evidence: the line, the PR, the date>` and close (`not planned` for standing gaps; §Hard limits — whose issue it is) |
| **requeue** | a `reread:` input whose blocker no longer holds and whose work is one ride from done (a salvaged branch, a blocker that was that ride's own) | labels: remove `agent/blocked`, add `agent/queued`; `intake: requeue — <the fact that changed, with its evidence>`, naming the resumable branch when the ride record has one (the next round resumes it) |
| **standing** | a valid gap the island records honestly and nobody should spend a ride on now | `intake: standing — <why not now>` (the selector skips it from then on); no labels |
| **split** | one input carries deliverables owned by two or more islands (typically an attribution input) | `file` one issue per island-owned part — its body names the island, narrows `Touches` to that island's paths, `Origin=<the input>`; one `intake: split → #a, #b` comment on the input, then close it (§Hard limits — whose issue it is; an input you may not close stays OPEN, the split comment its outcome). A part owned by ANOTHER island is filed and left for that island's sitting (no labels, no outcome) and is DUMB: that island's title cue, the input's text verbatim, one line naming the part — you never write another island's deliverable; a part owned by yours is decided in this sitting like any other input |
| **file** | a `text:` input worth an issue, or a parity gap (step 3; `Origin=<the input>`) | create the issue (machine block through the writer, `Origin=<source>` as prose when the source is not an issue), then decide it like any other input in the same sitting — unless ANOTHER island owns it: then title it with that island's cue and leave it for that island's sitting (no labels, no outcome), as `split` does |
| **forward** | the whole input is another island's (step 0): the fact, gate or path its fix would change is owned there, whatever the filer named | retitle the issue to that island's title cue (its facts file's membership line), nothing else in the body; ONE comment `intake: forward → <island> — <the owned thing, one line>`, quoting the old title. No labels. That island's selector offers it at its next sitting |

## The procedure, per input, in this order

0. **Whose is it?** (every `issues:` input — a member's island was named by its filer, an
   attribution input's by nobody.) Name the island(s) that own what its fix would change — the
   gate that went red, the rule that produced the wait, the path — from the facts files'
   membership lines ([`docs/intake/`](../../../docs/intake/), one file per island; you read those
   lines, never another island's owning docs). All yours → continue. All one OTHER island's →
   `forward`. Two or more islands → `split`. You never decide another island's part — its
   sitting does.
   **A path no island's membership names is the commons, not a missing owner** (the platform
   not yet split is held by the `agent-loop` and other pre-island rows; the rest nobody wholly
   owns and anybody may change within reason). A commons part goes with the island whose own
   thing it serves (the gate it wires, the lane that reads it): yours → decide it with your part;
   another island's → it rides that island's `forward` or split part. "Within reason" is the
   queue bar (one ride, a bounded `Touches`, every path `machine-merge`); past it the item is
   `goal` or step 3's, never `seat` for want of an owner.
   **The cap.** An input whose row says `forwards: 2` (or more) is not forwarded again, nor sent
   back to the island whose `intake: forward` sent it: that refusal is step 3's entry (d),
   naming the islands that passed it and what each said it lacked.
1. **Is it still real?** Live-verify against the spec page and the repo: the flag is on the line
   it names; the behaviour the body describes is still what the row says. A claim that no longer
   holds is `close` with the evidence (the line, the PR that changed it, the date). Trust the
   classifier over the body: a body that says "codeowner path" is a claim — run
   `classify_touches "<Touches>"` and believe the output.
2. **Is it already owned?** An open sibling on the same requirement → `fold`. A PR merged since
   filing that did the work → `close`. An open Goal whose acceptance names the surface → bind the
   issue as that Goal's native sub-issue; it is `queue` under the Goal's `Base` (read it with
   `issue_body.py get Base`), unless the Goal is closed or in `goal/post-launch` with the surface
   already shipped — then it is not covering, treat the item as standalone.
3. **Does it need the operator?** (ADR-164) Only for an entry of this closed list (a facts file's
   `Operator-only` / "`seat`, always" lines are its instances):
   - **(a) access or money** — a credential or login the island does not hold (a key mint, a
     subscription login), or spend beyond what is granted (a paid tier, hardware);
   - **(b) attended or irreversible** — the surface is `attended` or `manual` in the box's
     [capability ledger](../../../docs/management-box.md) (an `unattended` one is the box's window and
     queues), the act needs hands on a box, or no revert PR undoes it;
   - **(c) direction** — admitting a Goal above the ceiling (step 4), or what the island is for:
     its location, who consumes it, a switch-over or retirement, machinery its facts reserve;
   - **(d) another owner's gate** — a path `classify_touches` calls `codeowner-author`, a lane
     the island does not run, or a part islands refused (step 0's cap); a part another island
     owns is `forward`/`split`, not this;
   - **(e) a pending ruling** — the tracker (an FU line) or the item records an operator answer
     as pending on THIS question;
   - **(f) not yours to close** — §Hard limits keeps the issue (another human's; a close of a
     recent operator-login one).
   `seat` names the entry and the one fact. **No entry → you decide**: pin ⚖ the
   cheaper-to-reverse option, name the options you did not take with the reason each lost (as
   rejected options, never as open facts for the worker), go on to step 4 — production
   feedback (alerts, the dig, step E, a prober ride) corrects a wrong pin. **You decide on
   evidence.** When the fix is a choice between means (raise a limit, shrink what consumes it,
   clean up sooner), read what each costs and whether it fits (§What you read — a fact the
   decision stands on) before you pin; the body carries the choice and the numbers it stood on.
   A worker implements a decision; it never makes one. A scope you cannot pin
   is a `goal`, a `split`, or the smaller scope pinned ⚖. An option that blinds its own detector
   (a read pinned to an old upstream revision so a staleness alert goes quiet) is excluded
   without asking.
   **A ruling is the operator's recorded answer; it binds the question it answered** (the rows,
   pins or heading it decided). Any text under the operator's login that answers the question —
   a `text:` input, an issue body, however phrased; a lean counts — is one: quote it in the body,
   mark what it decides ⚖, decide as if the fact were on the page. Asked again: the ruling
   stands. Another question: it does not decide it, and a sentence beside it that would forbid
   this item's means is spec prose the body edits as an exception (§A queue-ready body), the
   ruled answer intact. Never a `seat` asking for a ruling again or for wording it did not decide.
   **Waits on another item.** No entry holds and the item waits only on an open issue or PR →
   `seat` with `blocked-on: issue=<n>` / `pr=<n>`; the wait ends when that item closes or merges
   (step R).
   **The parity check.** When part of the wait is a fact the island reads for a sibling
   (§Island facts names the sibling sets) through a facility this member lacks (a view, a read
   leg, a gauge a sibling has under the same page), the facility is a gap the contract implies:
   `file` it, the siblings' requirement as the template for its key rows (⚖ where this member
   differs), and decide it in this sitting. The original keeps what remains — an entry,
   `blocked-on: issue=<n>`, or nothing, then decide it. Parity never invents a facility no
   sibling has. The filed part and its origin are disjoint: step 2 never folds one into the
   other, and a re-read of the origin treats its parity issue as filed. No sibling set in the
   facts, no parity check.
4. **How big is it?** One ride → `queue`. More → `goal` within the ceiling, else `seat` (entry
   (c)) with the draft Goal below the comment's first line — breaker #1 is the operator's. A
   `seat` whose body now argues for an option the operator ruled out gets its body rewritten to
   what stays open (§Hard limits — whose issue it is).
5. **Is it worth a ride now?** A gap row that is honest, read by nobody live, and whose fix would
   buy the contract nothing it uses this month is `standing`, not `queue`. Say why in one line.
   "Worth it" is the island's contract gaining a row it relies on or losing a gap a consumer hits;
   it is not "the issue exists".

**R. A `reread:` input — is the wait still true?** Read the comment that parked it (on a
`pr-hold` row: the PR's newest `blocked-on:` marker, and the failing check it names) and name the
ONE fact it waits on. Then test that fact, not the comment: the ride record (did the work finish?
what stopped it?), the loop-worker PRs merged since (was the blocker that ride's own?), the alert
or gauge, the spec line, the ruling the tracker called pending, the done-when the body offers
(has one of them already happened?), and whether the wait still maps to an entry of step 3's
list — one that maps to none has changed. A `blocked-on: issue=` / `pr=` whose target closed or
merged has changed. Changed → decide the item afresh through steps 1–5 (`requeue`, `queue` after
a rewrite, `close`, `standing`). Unchanged → no write; the report says which fact you tested and
where. Never restate a wait in a second comment. A wait that narrows (one of its facts filed as a
parity gap) has changed, and gets the one comment naming what remains. **A `pr-hold` row is
decided in the report only**: no label and no comment on the issue or the PR — the report gives
the outcome, the fact tested, and the one instruction the next round needs; its receipt line is
`deferred`. (The scan releases a PR-level `blocked-on: human` on a human's comment only; what
else may release it is not ruled.)

**E. An `escape:` input — what intake let through.** Follow
[`intake-escape.md`](intake-escape.md) on the PR: classify each blocking review finding of each
round (A written into the body / B body silent, fact in the read set / C decidable before the
ride, outside the read set / D worker / E reviewer process) and write one record per finding into
the report's `## Escape records` (the receipt carries them). A class — the letter plus the intake
check the record names — sighted on two inputs (this sitting's, or an `escape-prior:` record) is
`file`d as one issue against the file that would carry the fix: this brief, a lens brief, or the
island's facts file; `Touches` = that file, `Origin` = the PRs, both records quoted — filed, not
decided here (the sitting of the island that owns that file decides it). Only A, B and
C are intake's; D and E records stay report-only. A class already filed whose target file has not
changed since writes nothing — the open issue is the record.

**W. A `wait:` input — what intake held back.** Follow [`intake-wait.md`](intake-wait.md): classify
the wait (H the operator's fact / R decidable from the read set / O decidable outside it / U not
judgeable yet), one record per input under the report's `## Wait records`, and a proposed edit
only for a rule line the ledger puts at the bar. No GitHub write.

Cap: **at most 3 `queue` outcomes (`requeue` included) per sitting; one Goal's children count as
one.** The cap limits `queue`, not
deciding: decide EVERY input. Only an input whose outcome would be `queue` and arrives over the cap is
left for the next sitting with no write at all (the selector re-offers it) — the report lists it as
`deferred (cap)`.

## Experiment — the ruling's own check, written before the result

A `queue` or `goal` ruling claims that its means removes the problem. Where a series can show the
problem, the body says how that claim is read after the merge: a scheduled read decides it from the
series, with no session in its path, and a failed one comes back to you as an input. You write it
once the means is decided (steps 3–4), into every queue-ready body — a Goal's children; the Goal's
own body carries none.

- **One of two, always.** A body whose problem is visible in a Prometheus series carries one
  `## Experiment` section; any other body carries the one line
  `Experiment: none — <why no series can show it>`. Never both, never neither. Under a Goal the
  section is on the child whose merge the claim is about; the other children carry the line.
- **Shape.** One prose line, then one fenced `experiment` block. The body passes
  `python3 -I islands/intake/scripts/experiment.py load --check <body file>` (exit 0; 3 with the
  `none` line) before you post it; that script's header is the format, and no key is added to it.
  `requirement` names the spec rule on a `spec` body, the alert or the `## Sources` row the decision
  stood on on an `edit` body.
- **Series.** The claim is read from a row of the facts file's `## Sources` whose note says
  `experiment`. A facts file that marks no row gives `Experiment: none`.
- **Baseline.** `baseline` is the `query`'s value over the baseline range, read by you:
  `python3 -I islands/intake/scripts/experiment.py at --prometheus <the Prometheus of your live reads> --query '<the query, with $window>' --window <the baseline range> --at <its end, RFC3339>`.
  The prose line gives that range and the count behind the number.
- **Threshold.** `pass` is fixed before the result. Once the ruling comment is posted nobody edits
  the section — not a re-read, not the worker.
- **Window.** Long enough that the baseline rate expects at least three events in it, and at most
  `7d`. When `7d` expects fewer: `Experiment: none — baseline too thin (<n> in <range>)`. It starts at the merge that
  ships the fix: the closing PR's, or for a child merged into `goal/<n>` the Goal's assembly merge ([`CONTRACT.md`](../CONTRACT.md) §Experiments).
- **"Stays at zero".** A claim that a count stays at zero sets `min_window` = `max_window` and
  joins one `and on() (<the source was observable over $window>)` term to its `query` (the
  exporter was scraped, the series existed), so that silence answers nothing instead of zero. The
  prose line names each `and on()` term in plain words.
- **A fix that changes its own measure** — the series, or the alert rule it would be judged by —
  gets `Experiment: none — the fix changes its own measure`, or a query on a series the fix leaves
  unchanged.
- **The label.** A body that carries a block gets `experiment/open`, set with its queue labels in
  the same write. A body with the `none` line never gets it.
- **A failed experiment comes back.** A reopened issue whose comments carry the scheduled read's
  experiment verdict is an undecided input, whatever earlier `intake:` outcome it carries: decide it
  afresh through steps 1–5 with the verdict as a fact. Its new body carries a new block with a new
  `id` in place of the old section — or the `none` line.

## Review and repair — before any label

A `queue` or `goal` outcome (a parity issue you `file` and decide `queue` included) is reviewed once
before the loop can see it, by sessions that never wrote its bodies. Other outcomes are not reviewed. **The review never holds the queue:** the repair pass ends in the
labels whatever the findings say, and the outcome stands.

1. **Write, do not label.** Write every body of the outcome (for a Goal: the Goal, its branch, its
   children, edges, dispositions, `goal-lint` PASS) and leave it there — no label, no `intake:`
   comment yet.
   The report lists the review units under `## Review units`, one line each:
   - `unit: <owner/repo>#<n> [#<child> …] base=<sha>` — one issue, or a Goal with every child;
     `base` is the default-branch commit your reads stood on;
   - `rows: <owner/repo>#<n> base=<sha>` — each `spec` body of the unit (§A queue-ready body:
     the one shape that carries `## Spec changes`). An `edit` body gets no `rows:` line.
2. **Two lenses, once each.** The launcher runs [`intake-review-unit.md`](intake-review-unit.md)
   on each `unit:` line and [`intake-review-rows.md`](intake-review-rows.md) on each `rows:` line,
   each as a separate session. The rows lens runs only on a `spec` body; an `edit` body is read
   by the unit lens alone. You never run a lens and never review your own bodies. A rows
   review whose `## Pass 1 (frozen)` section is empty (no line at all — `- none` is a line), or a
   lens run that wrote no findings file, is a failed run: it is re-run once, and a second failure
   skips that lens for that body.
3. **One repair pass.** Its prompt carries your first-pass report and every lens's findings
   file. Answer every finding by its id, once:
   `changed: <what you edited>` or `declined: <reason, with the source that decides it — a page
   line, a pin, a recorded ruling>`. Edits go through the same writer and gate (§A queue-ready
   body). The lenses do not run again on the repaired bodies — a loop until approval does not
   converge.
4. **Post, label, decide — in that order.** On each issue of the unit, ONE comment:
   ```
   intake: review — <n> findings: <k> changed, <j> declined
   <one line per declined finding and per advisory: id — the finding — your answer>
   ```
   (a skipped lens adds the line `<unit|rows> review skipped — failed twice` under the first).
   That list is for the worker. Then the labels, then the outcome comment, so the latest `intake:`
   line on the issue is the outcome.

In dry-run nothing is posted, so nothing is reviewed live; the report still carries
`## Review units` and the bodies, and a harness may run the lenses on them.

## A queue-ready body — one of two shapes

A body has one of two named shapes. The island's facts file names its default in one line,
`Body shape: spec | edit`:

- **`spec`** — the item changes a requirement on a spec page: the template with `## Spec changes`.
- **`edit`** — the item has no spec page: exact edits and check commands, a `## Decision`, no rows
  table.

Both carry `## Experiment`, or its `none` line, after the part that decides the means (§Experiment).

An item with no spec page on a `spec` island uses `edit`. No body carries a table written to fill
a heading.

### The `spec` shape — the spec is written into the issue (rule 2)

The pinned process says an issue "carries a handful of key rows (the happy path + the failure
modes worth a conversation)"; the worker grows the boundary rows and the specs reviewer gates
them. **You write the key rows.** Trust the reviewer to catch a wrong row; do not hedge a row into
prose to avoid being wrong — a row the reviewer bounces costs one round, a vague issue costs a ride.

````markdown
<machine block — written by issue_body.py set, never by hand:
 Touches=<the spec page, the test file, the src module — exact paths>
 Origin=<kept verbatim when the input already has one; else owner/repo#<the input, or the survivor>>
 Class=fix|build  (mirrored by the task/* label)>

## Deliverable
<ONE sentence: the thing that exists when this is done.>

## Acceptance
1. <checkable; names the rule id and the row>
2. …

## Spec changes
Requirement: `<RULE-ID>` on `<the spec page>` — world `<world>`.
| description | <input cols> || <expected cols> |
|---|---||---|
| "<the happy path>" | … || … |
| "<the failure mode worth a conversation>" ⚖ | … || … |
Index row: delete `⚑ gap (<date>, PR #N → work #M): …` verbatim / trim it to `<the remaining text>`.
Unverified: <what you did not read on the wire — "verify during implementation">; never a fact the fix depends on.

## Experiment
<ONE line — the claim in plain words, the series, each `and on()` term in plain words, the baseline's range and the count behind it. For instance:> No widget job fails in the 7 d after the merge, while the widget exporter was scraped for over 95 % of the window — series `widget_job_failures_total`; baseline: 6 failed jobs of 41 over the 14 d to <the read's instant, RFC3339>.
Written at intake, before the result. Not the ride's to change: no PR and no comment edits this section.

```experiment
{"id": "<island>-widget-jobs-not-failing", "requirement": "<the rule id, as in Requirement above>", "cases": [], "kpi": {"query": "(sum(increase(widget_job_failures_total[$window])) or vector(0)) and on() (min(avg_over_time(up{job=\"widget-exporter\"}[$window])) > 0.95)", "pass": "<= 0", "baseline": 6, "min_window": "7d", "max_window": "7d", "min_samples_query": "sum(increase(widget_jobs_total[$window]))", "min_samples": 20}}
```
<When no series can show the problem, the one line "Experiment: none — <why>" stands in place of this whole section (§Experiment).>

## Out of scope
<the sibling gap on the same row that stays; what step 3 left to the operator>
````

### The `edit` shape — exact edits, no rows

````markdown
<machine block — written by issue_body.py set, never by hand:
 Touches=<the files the acceptance lines edit — exact paths>
 Origin=<as in the `spec` shape>
 Class=fix|build  (mirrored by the task/* label)>

## Deliverable
<ONE sentence: the thing that exists when this is done.>

## Acceptance
1. In `<file>`, the line `<the old text, verbatim>` reads `<the new text, verbatim>`.
2. `<command>` prints `<its expected output>`.
3. …

## Decision
<The means chosen, one sentence — decided here; the ride implements it and decides nothing.>
The numbers the choice stood on, each with its read (the query, the file and line, the object):
- …
Options not taken, each with the reason it lost:
- **<option>** — <the reason>
Unverified: <as in the `spec` shape>; never a fact the fix depends on.

## Experiment
<As in the `spec` shape: the claim line, the line for the ride, one `experiment` block — its `requirement` names the alert or the `## Sources` row the decision stood on. Or the one line in its place.>
Written at intake, before the result. Not the ride's to change: no PR and no comment edits this section.

## Out of scope
<what stays as it is; what step 3 left to the operator>
````

Every acceptance line is an exact replacement (the old text, the new text, the file) or a command
with its expected output. The body carries no rows table.

### Both shapes

The bullets that name rows (`Touches` naming the `rule(…)` test file, "you state the rows",
"quote before you author", the `⚑ gap` flag) bind a `spec` body; every other bullet binds both.

- The machine block goes through `python3 agents/issue_body.py set … < body > final` and the
  gate `python3 agents/issue_body.py json < final` (exit 2 ⇒ fix, never post) — README §Authoring
  an issue body. Keep the prose free of machine lines; a hand-typed `Touches:` survives beside the
  block and misleads every human reader.
- `Touches` names the test file that will carry the `rule("<RULE-ID>")` label, so the footprint hold
  serialises two issues on the same requirement instead of letting their PRs collide.
- You state the rows, never the process: the worker's recipe (`.agents/fix.yaml`) carries the
  `Spec changes:` heading (rule 1) and the ratchets.
- **The body is for a worker that does what it is told and does not reason** — the cheapest
  model on the rail may ride it. Every acceptance line is an edit, or a command with its expected
  result. No line asks the worker to choose, to measure before it can choose, or to "stop and
  report if …" on a fact you could have read; `Unverified` never holds a fact that would change
  `Touches`, the means or a number in the body. Before you write it, check the ride can do it
  (§What you read — what the ride can do): no `Touches` path the recipe bans, and every read an
  acceptance line needs is one the pod's reach allows. What the worker cannot read, you read,
  and it goes into the body as a fact with its source.
- **Which ⚖ is which.** In an issue body `⚖` marks a row or pin with a plausible alternative
  (rule 4) — a flag for the specs reviewer on a choice already made, never an open question. A
  fork on step 3's list is not a `⚖` in the body: it is `seat`. An island's facts file
  may tighten this (e.g. `⚖` for operator forks only, row alternatives written under
  `Unverified`). A row you could not ground in the page or a merged PR is marked
  `verify during implementation` (rule 10), never asserted — unless the fix depends on it (the
  row decides the means, `Touches` or a number in the body): that fact is read first, or the
  input is `deferred (fact)` (§What you read).
- **Quote before you author.** Where an existing row, a sibling's row or the page's own text
  already says it, copy it verbatim and name where it came from; author a new table only for what
  no row says yet. A quoted row is still read. Before it goes into the body, read it yourself as
  the rows lens will — the author's own reading, not a lens run: description covered, fixture and
  patch names ignored, its input cells and the requirement prose must decide every expected cell.
  Where they do not, `## Spec changes` carries the missing input column or prose clause, and the
  body does not call that row unchanged.
- **An exception names the universal it breaks.** When a row adds an exception to a universal
  sentence elsewhere (a sibling's Deliverable, requirement prose, a glossary row), the body names
  that sentence's edit and its file is in `Touches`.
- **A `⚑ gap` flag whose `→ work #M` is closed with the shortfall still real** has two honest
  fixes, and you choose: `file` the successor work issue (decide it in the same sitting — usually
  `standing`) and re-point the flag at it, or re-point at the closed issue's comment that names
  the residue, ⚖. Rule 10's grammar names a work issue; a dead pointer is the one thing a flag
  may not carry. A successor you file carries `Origin=<the input you are deciding>` (the sitting's
  provenance); the closed work issue is named in prose.

## A bot-authored Goal

Follow the consumer card's three acts exactly, with these pins:

- **`Budget:` ≤ `INTAKE_GOAL_BUDGET_USD` (default 30).** Write the ceiling when nothing in your
  read set prices a ride — an unpriced Goal is not a `seat`. Above it, `seat` with the draft — a bigger
  Goal is the operator's to admit. The number is money; `Budget` is the only money truth.
- `Base: goal/<n>-<slug>` — fill `<n>` after filing and cut the branch from the default branch
  yourself (`gh api -X POST repos/<slug>/git/refs -f ref=refs/heads/goal/<n>-<slug> -f sha=<master
  sha>`); `goal-lint` fails on a missing branch. `Base: master` is not yours to choose.
- `Verdict-authority: human`; `Production-leg:` the deploy surface (the image bump the island's
  deploy path rolls, a named gauge or row reads the new behaviour).
- `## Goal` states the intent, the acid test and the design pins; `## Acceptance` numbered;
  `## Out of scope` names what the children must not drift into; a line `Authored by island
  intake from <inputs>`.
- Children: 2–5, each a queue-ready body (above) with `Base` inherited verbatim through
  `issue_body.py get Base`, `Touches` narrowed, `Class`, `Origin=<slug>#<goal>`; bound as native
  sub-issues (`sub_issues` POST); ordered by native `blockedBy` edges where one must land first;
  `epic_dispositions.py set <slug> <goal> <child> adopted --by checkpoint` for each.
- `devbox run goal-lint -- <slug> <n>` PASS **before any label**. A FAIL is fixed on the issue.
  The labels then wait for §Review and repair (the Goal and every child are one unit).
- **`agent/queued` on the children only. Never on the Goal.** Breaker #1 refuses a Goal queued by
  a loop identity, by design: the Goal's gate is its verdict, and this sitting runs inside it. A
  Goal you authored whose children exist stays unqueued (consumer card, act 3).

## Hard limits

- **No code, no PRs, no edits to the island's files.** Your writes are issues, labels, comments,
  sub-issue and `blockedBy` edges, one branch ref per Goal.
- **Whose issue it is, and how old (ADR-163).** A bot-filed issue (`app/homelab-agents-1234`, any
  `[bot]`) may be closed, folded, split or rewritten with the evidence. An issue under the
  OPERATOR's login may too, weighted by age: the older and staler it is (the claim moved, the work merged, the done-when happened),
  the freer your hand — close it or rewrite it on the evidence; a recent one gets light editing
  only (the machine block, the key rows, a narrowed `Touches`) — its intent stays as written, and
  when you would close a recent one, it is `seat` (entry (f)) with the recommendation instead. Every close
  or rewrite of an operator-login issue keeps the original body recoverable (the comment quotes
  what was removed or says "rewritten; the original is in the edit history") so one push undoes
  it. Any other human's issue is never closed, folded or rewritten: `seat` (entry (f)). A `forward` is the
  light edit on any bot-filed or operator-login issue, whatever its age (the title cue only; the
  comment quotes the old title). A `split` of a recent operator-login issue files the parts and
  leaves the input open (nothing of its text is lost or closed).
- **Idempotent writes.** Re-read labels and the last `intake:` comment immediately before writing;
  an item carrying any `agent/*` label or an earlier outcome is not yours this sitting — unless it
  came as a `reread:` input, where `agent/blocked` or the `seat` outcome is exactly what you test,
  or was reopened by an experiment verdict (§Experiment).
- **One comment per outcome**, first line `intake: <outcome> — <reason, one line>`; a `seat` adds
  `blocked-on: human` — or `blocked-on: issue=<n>` / `pr=<n>` (step 3) — on its own line. A reviewed outcome
  adds exactly one `intake: review` comment before it (§Review and repair). No second comment to "clarify".
- **Rate.** REST reads only, each item once; never poll. The sitting is one pass.
- **No credential, ever, in a body or comment** — the repo is public.

## Report (the product in dry-run; the receipt in apply)

```
| input | outcome | written (labels / issue ids / branch) | reason (one line) |
```
then, verbatim, **every body you posted or would post**, then `## Review units` (§Review and
repair; the repair pass adds each finding id with its `changed:` / `declined:` answer), then
`## Escape records` (step E), then `## Wait records` and `## Wait proposals` (step W), then **Facts I lacked:** one line each —
the fact, where you looked. That list is the spike's evidence (which reads the brief is missing);
never pad it, never leave it out.

## Island facts

The island's facts file, named by the launcher (a platform island's is `docs/intake/<island>.md`,
a stack island's lives in its own repo — ADR-160): read it in full after this brief. Every facts
file has three parts: the island's facts, `## Sources` and `## What a ride can do` (§What you
read); one that lacks a heading, or whose `## Sources` table has no row, fails the island's test.
