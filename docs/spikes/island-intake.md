# Spike — island intake: the gateway admits its own ordinary work

_Opened 2026-10-27 (operator ask: an overnight, unattended spike — "the main problem to solve is
adding the `agent/queued` label … right now I am the blocker in queueing issues"). Status:
**a brief + a selector built and run twice against the live pile (dry-run, then apply); no
decision taken here** — the wiring was RULED and BUILT 2026-10-28 (its own CronWorkflow, dig
source first — §Open questions 1, #3004); the remaining rulings in §Open questions are the
operator's; tracked by FU-320. Relates: [`context-and-autonomy.md`](context-and-autonomy.md) §The plan **P6**
(machine admission for `agent-fix` filings — "safe once the lens is the gate") and §C7 (islands),
ADR-139 (the island), ADR-155/156 (the specs reviewer — the lens that makes P6 safe here),
ADR-122 (one parser, dispositions), ROADMAP §"Intake is the open front end", FU-270 (the island's
pointer), the coordinator's `goal-decompose` clause (the ancestor:
[`agents/coordinator/README.md`](../../agents/coordinator/README.md))._

## The question

Can a sitting with ONLY the island's context — `gateway/` + the authoring grammar, no corpus —
read the island's unshaped inputs (inert issues, tracker text, meta-state bullets) and leave each
in a state the loop already understands: queued with the spec written into the issue, a Goal
tree whose assembly keeps the codeowner read, a `blocked-on: human` marker naming the one fact
it lacks, or a close with evidence — well enough that the operator reads PRs instead of the pile?

## What was built

- **The brief** — [`gateway/intake.md`](../../gateway/intake.md): seven outcomes (`queue`, `goal`,
  `seat`, `fold`, `close`, `standing`, `file`), a five-step procedure (still real? → already
  owned? → needs a human fact? → how big? → worth a ride now?), a queue-ready body shape that
  carries the KEY ROWS (pinned rule 2: "an issue carries a handful of key rows … the implementing
  agent adds boundary rows"), the bot-authored Goal's pins (budget ceiling, `agent/queued` on the
  children only — never on the Goal, so breaker #1 stays the human's and the assembly's codeowner
  read stays the gate), the hard limits (no code, no PRs, never close a human-filed issue, ≤ 3
  queued per sitting, one `intake:` comment per ruling), and the island facts.
- **The selector** — [`gateway/scripts/intake-select.sh`](../../gateway/scripts/intake-select.sh):
  the deterministic half, in the scan's own shape. Island membership (title, else every `Touches`
  entry under `gateway/**` through the one parser), no `agent/*` label, not a Goal or container,
  no standing `intake:` ruling. Fires at ≥ 3 unruled issues or the oldest ≥ 24 h; exit 2 when a
  read failed (an empty answer is not a verdict).
- **The marker** — a comment whose first line is `intake: <outcome> — <reason>`; a `seat` adds
  the existing `blocked-on: human` line (README §Blocked-on marker), so the scan's suppression
  predicate and the board's ⏸ SOLVE line already read it. No new label, no new grammar.

What it reuses unchanged: `issue_body.py` (the machine block), `classify_touches` (the write
tier), `goal-lint`, `epic_dispositions.py`, the consumer card, the `task/*` labels, the specs
reviewer as the gate on every row the worker lands.

## Run 1 — dry-run (2026-10-27, opus subagent, 153k tokens, 42 tool calls, 6.5 min)

Inputs: the selector's five (`#2782`, `#2768`, `#2753`, `#2684`, `#2650` — 159–263 h unruled)
plus FU-271's text. Wrote nothing. Rulings:

| input | ruling | the one-line reason |
|---|---|---|
| #2782 (janitor-filed) | queue | the GW-MODEL-TIERS index row flags `→ work #2718`, closed 10-20 with items 2 + 5 open; one index-row edit |
| #2753 (janitor-filed) | queue | PR #2710 closed #2685 and left its own flag + gap row on GW-SESSIONS-AUTH; the closure is already proven by two existing rows |
| #2768 (operator-filed) | seat | needs the ruling FU-270 lists as operator-only (what a rail-served-but-unlisted id is) |
| #2684 (operator-filed) | standing | the gap row is honest and its trigger (an SA that must not ride in a listed bind namespace) is not shown |
| #2650 (operator-filed) | seat | two done-whens, one is a maintenance window; the body says the seat sequences it |
| FU-271 (text) | standing, not filed | a measurement then a store decision, after FU-270; the spec already renders it as a gap |

What the sitting caught that the pile did not say: **both janitor bodies claimed
`gateway/specs/**` is a codeowner path; `classify_touches` says `machine-merge`** — the island's
specs are worker-writable (three worker PRs with spec rows merged that week: #2862, #2883,
#2961). The bodies it drafted name the exact flag text to delete (grep count 1 against the live
page), the rows that already evidence the closure, the ⚖ alternative, and "verify during
implementation" where it could not read (`spec_gate.py`'s pointer grammar).

Its "Facts I lacked" list became four brief amendments before run 2: a text input ruled
`standing`/`close` is report-only (no `file`); `seat` on an item whose body keeps it out of the
loop writes the comment only, no labels; a `⚑ gap` flag whose work issue closed has two honest
fixes (file the successor, or re-point at the residue comment ⚖); the pinned RULES.md is in the
read set.

## Run 2 — apply (2026-10-27 ~21:20Z, opus subagent, 152k tokens, 41 tool calls, 6.5 min)

Same inputs, the amended brief, writes granted; run 1's output handed over as a draft to
re-verify, not to replay. Every claim re-checked live (the flag lines, the merged PRs, the
deployed `policy.json` callers, `classify_touches` with a positive control). Written:

| input | ruling | written |
|---|---|---|
| #2782 | queue | body rewritten; `agent-fix` + `task/fix` + `agent/queued`; the flag re-pointed at a filed successor |
| ↳ **#2977** | file → standing | the successor work issue for #2718's three standing shortfalls (parseable block, done-when per shortfall, the trigger to pick one up); `intake: standing`, no labels |
| #2753 | queue | body rewritten (the world column restored; a stale fixture-SA spelling in the world prose found and parked ⚖ out of scope); same labels |
| #2768 | seat | `agent-fix` + `agent/blocked`; `blocked-on: human` naming the ruling |
| #2650 | seat, comment only | no labels — the body keeps it out of the loop (the amended rule) |
| #2684 | standing | comment only |
| FU-271 | standing, report-only | nothing |

End state: the selector went from `fire: 5` to `hold: 0`; the seat rang the platform doorbell
after the run. Run 2 graded run 1: same ruling on all six, two bodies changed (the #2782 flag
form — the draft had named the closed issue, which neither honest fix allows; #2753's table had
dropped the page's `world` column). Facts it lacked: whether `spec_gate.py` reads the `→ work`
pointer (marked "verify during implementation" — the worker's); whether a listed bind namespace
holds an SA that must not ride (#2684's own trigger, `kubectl` forbidden by the brief); which
`Origin` a filed successor takes (now ruled in the brief: the input being ruled); rule 10's flag
grammar for a requirement-level gap tracked by an FU id (`health.md`'s HA row — pinned-text
territory, §Open questions 4).

## Reading

- **The lens-is-the-gate premise held for the ordinary class.** Two queue rulings, both one-line
  spec edits with the key rows written, both on bot-filed issues; the worker's recipe already
  knows the ratchet; the specs reviewer gates the rows. Nothing in that path needs the operator.
- **The `seat` class is where the operator's minutes go, and it is now ONE line each** — the fact
  needed, not a pile to re-read: a ruling (#2768), a done-when pick + a window (#2650).
- **`standing` is the outcome the pile lacked.** Without it, every honest gap row re-surfaces as
  an unlabelled issue forever; with it, the selector skips it and the gap stays rendered in the
  spec (rule 10), which is where it belongs.
- **No Goal was needed by this pile** — the `goal` path (branch, children, dispositions,
  `goal-lint`, children queued, Goal unqueued) is written but unexercised. It is the path the
  operator asked for ("a goal with a branch where the same codeowners validation happens"); it
  needs a Goal-sized input to prove it.

## Open questions (the operator's)

1. **Wiring — RULED 2026-10-28 (operator): its own CronWorkflow, the dig as the first source.**
   Not a scan clause: scan units are item-shaped (`clause|repo|issue-N` — lanes, WIP, dispatch
   markers all key on an item) and the scan pod holds no bucket READER key, while an intake
   sitting is a batch over a pile. `agents/coordinator/island-intake-argo.yaml` runs daily at
   05:00Z (after the 03:30Z [deep dig](../agents/roles.md)): `intake-select.sh --source dig` →
   one sitting (goal-decompose class) on `gateway/intake.md` → a `receipt.json` per run (the
   ledger of ruled inputs) → one `/coordinate` ring when it queued. Spend is a budget knob
   (`INTAKE_DAILY_MAX`, the responder's cap shape), not code. Why the dig first: its
   `cause-found` findings reached a worker only through the seat (the 10-25 Go-catalog cause was
   dispatched ~45 h later as #2933); intake folds same-cause findings before filing, so the dig
   needs no issue author. The issue pile stays seat-run until wired as a second source; the
   gateway's own dedup store is a later concern (operator, same ruling).
2. **Budget ceiling for a bot-authored Goal** (`INTAKE_GOAL_BUDGET_USD`, default 10) — P6 said
   "Goals stay human"; the ask puts the human at the assembly read instead. The ceiling is the
   dial between the two.
3. **Human-filed issues**: the brief never closes or folds one (`seat` instead). Whether the
   operator wants the bot to close THEIR issues with evidence is a ruling, not a default.
4. **The `⚑ gap` flag grammar for a closed work issue** (run 1's finding): rule 10 names a work
   issue; the island already uses `⚑ gap (date, homelab#N)` for residue. One form or the other
   belongs in the pinned text (allure-behavior-snippets), not here.
5. **Other islands.** The brief's rules are island-agnostic; the §Island facts block is the
   gateway's. oracle-fleet has the same shape (specs, reviewer, read map) — the second island is
   where the brief's generality is tested.

## What would settle it

Days from bot filing to `agent/queued` ≈ 0 on the island without a seat touch (P6's own settle
number), over two weeks of selector firings; the queued issues' rides merging at ≤ 2 review
rounds (the rows were right); zero `seat` rulings the operator answers with "that was decidable
from the island's own text" (the read set was enough).
