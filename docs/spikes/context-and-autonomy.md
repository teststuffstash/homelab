# Spike — context engineering × loop autonomy: why the platform stalls

_Opened 2026-10-04 (operator ask, second-jail session, PR lane). Status: **findings + ranked
proposals, no decision** — every proposal below is an operator call; the quickfixes rode the
opening PR. Relates: [`doc-heat.md`](doc-heat.md) (FU-164 — the measured corpus loads),
[`no-human-in-the-loop.md`](no-human-in-the-loop.md) (the recovery-path end state),
[`codeowner-catches.md`](codeowner-catches.md) (the gate census), ADR-110 / ADR-122 / ADR-128 /
ADR-141 / ADR-146 / ADR-148, ROADMAP §"The platform lane sheds the meta crutch"._

## The question (operator, verbatim shape)

"The whole platform is stalled due to low autonomy in the loop + context explosion. Why do I have
76 open issues and an FU counter over 300 with old ones not getting done?" — read as one system:
the loop's **admission** is human, the human's **session** is where the context lives, and the
**records** that carry the human's context grow by narrative. Each feeds the next.

## Measured (2026-10-04, deterministic reads; commands in the PR that opened this)

### A. Context the human pays

| What | Size | Note |
|---|---|---|
| Static startup context, every seat session | **≈56–70 KB ≈ 14–17k tokens** | `scripts/session-ctx.sh --startup`: CLAUDE.md 18 KB, seat+jail cards 17 KB, MEMORY.md 25 KB (96 entries, lines up to 489 chars — an index that became content), 13 skill descriptions 6.9 KB |
| `/meta-coordinate` bootstrap adds | meta-state 32 KB + TICK-LOG tail + skill body 17 KB | meta-state.md's own contract says "tiny, transient"; it carries 18 ⚑ pickups, 3 older than two weeks, plus an OPERATOR-OWED list of 7 |
| `/design-agents` read plan | **836 KB static → 299k/346k tokens measured** | 18 `docs/agents/*.md` (625 KB) + the coordinator brief (143 KB) + glossary + CONTEXT/ARCHITECTURE; doc-heat run 2: 72 % of the plan's lines never targeted by any read or grep |
| Records | TICK-LOG 1.09 MB · adr.md 235 KB (111 ADRs, **54 over the ≤20-line rule**, median 20, max 169) · follow-ups.md 133 KB (1,408 lines, preamble 142 lines; the "Next free id" counter is one 1,748-char line) · GAPS.md 30 KB (one entry 85 lines) | the routing table's size rules exist and are not held: only the FU 10-line cap has a lint |
| Skills | 82 KB of SKILL.md, 12 of 13 open with "glance GAPS.md" (30 KB) | fu-sweep's description was 903 chars of procedure; board-sweep + fu-sweep still ordered the corpus preload the 09-27 rule forbids (fixed in the opening PR) |

### B. Context the machine pays

| Role | Injected | Shape |
|---|---|---|
| Coordinator pod | `agents/coordinator/README.md` **143 KB (~36k tokens) as `--append-system-prompt-file`** + item prompt + CLAUDE.md | one brief for every clause; no clause reads a slice |
| Worker | env card ~6.6 KB + ground-rules 3.9 KB + recipe 10–13 KB + issue + CLAUDE.md 18 KB | ≈42 KB — the right order of magnitude |
| Reviewer | prompt 19 KB + `.agents/review.md` 9 KB + lenses up to 21 KB + card | 30–51 KB |
| The scan | `agents/coordinator-scan.sh` **6,107 lines**; launchers 256 / 106 / 55 KB | the deterministic gate is itself a corpus — any edit is a design read |

### C. The backlog, by why it is open

- **homelab: 76 open issues, 0 `agent/queued`.** The scan's ONE dispatch precondition is
  `agent/queued` (ADR-122 (2), `coordinator-scan.sh` header). 44 are bot-filed; 42 carry no label
  at all; 49 have zero comments; 22 of 28 `agent-fix` issues were never queued (#1370 logged nine
  recurrences and was never dispatched). 18 of 76 are containers by construction (Goals,
  post-launch buckets, stints, scout digests) that close only when their tree empties. Three are
  done-but-open (#1621 `agent/done` since 09-14, #168, #1988). oracle-fleet (24 open, 2 queued,
  17 touched this week) shows the same three shapes but moves.
- **FU tracker: 132 open, median id 199, 35 below FU-150 (≥ 2 months), oldest FU-005 /
  FU-051 (07-05).** 74 of 132 (56 %) sit in the Agents block, although the routing table says
  agent-loop work items are GitHub issues. ~100 items carry a "Next:" — a next action exists,
  the actor does not: every one of them is the seat. 27 items exceed the 10-line cap. Minting ran
  ~3 ids/day (FU-246 → FU-303, 09-16 → 10-03); archiving ran 47 entries in five weeks
  — the set shrinks only in fu-sweeps, which are seat sessions.
- **ADR-128 census (08-04 → 09-11):** 273 human codeowner reads, 38 findings (13.9 %), 18 of
  them in-diff defects — the gate pays off at about one catch per seven reads, and ~6.7 reads a
  day before the narrowing.

### D. Where the human is (the gate inventory, from the loop diagnosis)

Codeowner read = corpus-loaded session (ADR-110) · `major/awaiting-human` (shrinking: Actions
and provider majors moved to the lens, ADR-141 + 10-04) · attended applies (FU-301, evidence
gated on purpose) · `agent/error` / `agent/blocked` breakers (a human removes the label) · the
arbitrate ceiling's "escalate" branch · Goal queueing (breaker #1) and verdicts · research/retro
PRs un-armed · governance files direct-to-master · App / console clicks · `/design-agents` typed
only · FU single writer · the `blockedBy` edge. Eleven gates; the TICK-LOG's last four days read
"operator", "by hand" or "codeowner click" ~40 times in 400 lines and "unattended" six.

## Reading it against the guidance

Anthropic's published guidance (the context-engineering post, Claude Code's CLAUDE.md and
subagent docs, the Agent Skills spec, the long-running-harness post) reduces to a few rules this
repo states for itself and then breaks:

1. **Smallest high-signal token set; "would removing this line cause a mistake?"** The seat card
   and CLAUDE.md are ~11–12 % long parentheticals retelling incidents. The operator's own
   2026-09-11 rule ("briefs are rules-only, history lives in the ADR/incidents") is the same
   rule; it was applied to pod briefs and not to the human's.
2. **Progressive disclosure: metadata always, instructions on trigger, references on demand.**
   Skills do the first two and then point at 97 KB and 838 KB documents instead of skill-owned
   excerpts; the coordinator gets its whole brief for every clause; `/design-agents` is the
   anti-pattern made policy — and doc-heat run 4 already showed the codeowner-read stream works
   on a topic slice at half the cost with zero misses.
3. **Just-in-time retrieval over pre-loading; an index of pointers beats the content.** The
   tracker is the hottest doc (grep 8× read) and it is read as a whole for every sweep; MEMORY.md
   is an index whose lines are the memories.
4. **Subagents isolate context; the orchestrator keeps the conclusion, not the file dumps.** The
   seat does this for reads but not for its own session shape: one session = board + tracker +
   corpus + infra windows + bookkeeping, and the wind-down writes 32 KB of prose for the next one.
5. **Long-running harness: a machine-readable task list with explicit pass/fail, one unit per
   session, leave the environment clean, the agent must not declare "done" without a test.**
   meta-state.md is that task list written as prose; "done-but-open" issues are "declared done
   without the acceptance observation".
6. **Workflows before agents; a deterministic step wherever one suffices.** The scan is the right
   instinct (no LLM wakes for a no-op) — and it has grown to 6k lines because every rule became a
   clause in one file.

## Diagnosis — three loops, one actor

- **Admission loop.** The machine files (44 bot issues) faster than the one human admits (0
  queued). Filing without admission is what "inert" (ADR-122) means, so the backlog is the design
  working — on a repo whose only admitter is a session that also does everything else.
- **Session loop.** The admitter's session starts at ~15k tokens of rules, adds 32 KB of pickup
  prose, and either pays 300k for the corpus or is told it may not judge agents items. Fewer
  decisions per session → more pickups → longer meta-state → fewer decisions.
- **Record loop.** Every decision becomes 20+ lines of ADR, every loose end 10 lines of FU,
  every session a TICK-LOG entry and a GAPS sighting — and the human reads all of it because the
  records are the human's context. The tracker's own header diagnosed this on 2026-08-07 ("the
  block grew because every finding became an entry") and then grew another 150 ids.

The operator's stated boundary (ROADMAP: "autonomy grows on the INTAKE and FIX sides, never the
approval side") is consistent with everything below: nothing here lets a cluster identity approve
or merge. What moves is **admission, context shape, and record size**.

## Proposals, ranked by operator-minutes saved (the platform's cost function)

**P1 — Machine admission for the `agent-fix` class (intake side).** The filer that produces a
finding with a recipe, a budget label and a repo claim applies `agent/queued` itself; breaker #1
(a human must authorise a GOAL) stays; a human-only admission remains for issues touching the
governance core paths (the ADR-128 set) and for anything without a budget label. Dedup stays
best-effort on the filer (the 10-02 ruling). Evidence it is safe: oracle-fleet runs this shape;
the worst case of a bad admission is a bounded ride that fails review. *Settles:* homelab
`agent/queued` count > 0 without a seat touch for a week; the 42 unlabelled filings get a label
or a close reason from the filer.

**P2 — The codeowner read becomes a sliced, rubric-graded machine read; the human keeps the
governance core.** ADR-128 already narrowed the paths; doc-heat run 4 showed the topic-slice
selector works for this stream. Build: a `codeowner-read` reviewer lens that loads the owning
sections by path→doc map (the codeowner-queue audit's CORPUS-SUBSET map), grades the PR against
the ADR-110 escalation rubric (small = merge, big = `major/awaiting-human` with the fork named),
and posts the verdict; the seat reads only what it parks. The 13.9 % catch rate is the baseline a
drill must beat or match (reviewer-drill shape: deceptive PRs + an honest control). *Settles:*
`CodeownerParkWaiting` fires on the big only; catch rate on a two-week census ≥ 13.9 %.

**P3 — Context budgets become lints, and the briefs become sliced.** (a) `session-ctx --startup`
grows thresholds the pre-push hook enforces: CLAUDE.md ≤ 12 KB, seat card ≤ 8 KB, MEMORY.md
index lines ≤ 120 chars, meta-state ≤ 8 KB, an ADR block ≤ 20 lines (54 fail today — a one-time
distil, then the lint), GAPS entry ≤ 15 lines. (b) The coordinator brief splits into a ≤ 15 KB
always-on core (state machine, invariants, dispatch params) + per-clause sections the launcher
appends by `--item` clause — the same progressive disclosure skills already use. (c)
`/design-agents` keeps the full read as the exception and gains a default **slice mode**: the
path→doc map picks the sections, the grounding statement names them, and "a claim about a file
not read" (the 08-10 miss class) is caught by the reviewer, not pre-empted by a 300k load.
*Settles:* `--startup` total ≤ 40 KB; a design sitting on a slice produces a PR the bot reviewer
accepts without a corpus-miss finding across five sittings.

**P4 — The tracker returns to its contract: pointer-only, issues for agent work, expiry for the
rest.** The 74 Agents items move to homelab issues (labels carry section + state; the FU keeps a
one-line pointer until the issue closes, then archives) — the routing table already says so.
Open items older than 60 days whose "Next:" has not changed in 30 days expire to the archive
with `(expired YYYY-MM-DD — no actor)`; expiry is reversible by re-filing with a new actor. The
counter line shrinks to the id + the burned list; its minting history moves to the archive's
head. The lint gains the expiry report. *Settles:* open count ≤ 60 and falling; a sweep takes one
subagent round, not four.

**P5 — Containers and done-states close themselves.** `agent/done` + merged PR + acceptance
probe green (or no probe declared) → closed by the scan after a 48 h window; a post-launch bucket
with no open member for 7 days → closed; a stint container whose last PR merged 14 days ago →
closed with a summary comment. These are label-and-date predicates, i.e. scan clauses, i.e. the
machinery that already exists. *Settles:* the 18 container issues reach ≤ 5 without a seat click.

**P6 — The seat session becomes a harness, not a shift.** meta-state.md becomes a machine-readable
pickup list (one JSON or YAML row per item: id, owner, due, state, acceptance) rendered to prose
on demand; a session picks ONE unit (a codeowner batch, a window, a sweep) and ends; subagents
carry the reads (already the rule) AND the per-item write-ups (the PR body, the issue comment),
so the seat's own context holds verdicts only. *Settles:* seat sessions end under 150k tokens
with no `bookkeeping:` commit larger than 40 lines.

**Order.** P1 and P5 are scan clauses and can land in a week; P3(a) and P4's lint half are
scripts; P2 and P3(b/c) are the design forks and want an ADR each; P6 follows P3.

## Quickfixes that rode the opening PR

- `scripts/session-ctx.sh --startup` — the static startup-context meter + the design-agents
  read-plan size (bytes and a 4-chars/token estimate), so trims are measured, not felt.
- `CLAUDE.md` — three history passages reduced to their rules (18.0 → 16.8 KB).
- `agents/jail-seat-card.md` — the mechanism-history blockquote and two measured-history
  paragraphs reduced to their rules; every rule kept.
- `board-sweep` + `fu-sweep` — the "run the design-agents read plan first" rule (forbidden since
  2026-09-27) replaced by the slice rule; fu-sweep's and design-agents' descriptions reduced to
  when-to-use; a stale "34 of 57" figure replaced by "read the lint output".

## Loose ends found, not filed (second jail — the primary mints)

- GAPS.md has no §second-jail, §board-sweep, §fu-sweep, §docs-cleanup, §opnsense-as-code,
  §skill-retro sections although 12 of 13 skills demand the glance; 9 open GAPS entries carry
  ≥ 2 dates and none is promoted (the improvement contract's trigger is not running).
- MEMORY.md (auto-memory index) is 25 KB with 300–489-char lines: the index holds content,
  against its own rule; a one-pass re-index to ≤ 120-char hooks would cut ~5k tokens per session.
- meta-state.md carries three pickups older than two weeks and an OPERATOR-OWED list of seven
  items with no due dates.
- `fu-sweep` and `board-sweep` had not been edited since 2026-08-19 while the rules they encode
  changed twice.

## What would settle it

One number per proposal above, plus the system one: **seat-minutes per merged machine PR** and
**days from bot filing to `agent/queued`**, both derivable from GitHub timestamps and the
TICK-LOG session headers, measured on the two weeks before and after each change lands.
