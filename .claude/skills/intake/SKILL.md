---
name: intake
description: >
  The seat's admission pass — nothing that needs no operator input may sit waiting for it. Fans
  island intake out over every island: one sitting subagent per island (gateway/intake.md rules +
  docs/intake/<island>.md facts) over every unruled issue and every tracker item whose next step is
  mechanical, so each leaves in exactly one loop-readable state (queued / Goal tree / closed with
  evidence / standing / `blocked-on: human` naming the ONE missing fact). Use on "/intake",
  "queue what can be queued", "clean up the open issues", "what is waiting on me", "admission
  pass", or as the middle stage of a cleanup (board-sweep → intake → fu-sweep → docs-cleanup).
---

# intake — admission without the operator in the path

> **Glance first**: [`../GAPS.md`](../GAPS.md) §intake — unpromoted sightings apply until closed
> (contract: [`../README.md`](../README.md)).

**The invariant this skill owns:** the operator's queue holds only items that need the operator,
each as ONE line naming the missing fact (a ruling, a window, a mint, a verdict). Everything else
leaves the pass queued, closed with evidence, or ruled `standing`. The human gate stays where it
was designed — the PR read, the Goal assembly read (ADR-110), breaker #1 on Goals — and moves off
the pile.

No new mechanism: [island intake](../../../docs/glossary.md) is the sitting
([`gateway/intake.md`](../../../gateway/intake.md) — outcomes, procedure, hard limits), its
selector is [`intake-select.sh --island`](../../../gateway/scripts/intake-select.sh), each island's
facts are in [`docs/intake/`](../../../docs/intake/). This skill fans the sitting out across the
islands and feeds it the inputs the selector cannot see. Design + evidence:
[`docs/spikes/island-intake.md`](../../../docs/spikes/island-intake.md) (FU-320).

## Hard rules

- **Sittings rule, the seat dispatches.** The seat never rules an item from its own context — it
  would need every island's read set at once, the corpus problem islands exist to remove. One
  subagent per island; split an island over ~12 inputs into parts (each part gets its own ≤ 3
  `queue` cap).
- **Scope = the platform claim's repos** (seat triage scope). A stack repo's pile belongs to its
  stack loop/jail — report its counts, never rule it.
- **Operator-filed is human-filed.** The brief's "never close or fold a human-filed issue" binds the
  seat too — the jail identity is the operator's. A close candidate there is one operator line.
- **A loop-component design is `seat`, never `queue`** (the design-agents stop-and-ask trigger;
  [`docs/intake/agent-loop.md`](../../../docs/intake/agent-loop.md)).
- **Subagents write nothing into `/workspace/homelab`** — downloads, bodies and reports go to the
  scratchpad, under per-dispatch names (a shared `pr-body.md` put one PR's body on another,
  2026-10-31).

## The pass

1. **Board truth** — run [`board-sweep`](../board-sweep/SKILL.md) (or reuse today's report). Its
   do-nows on bot-filed items (superseded digests, empty post-launch buckets of validated Goals,
   latches whose cause has reset) are the seat's to execute now, each with an evidence comment.
2. **Select per island** — `bash gateway/scripts/intake-select.sh --island <i> --json` for every
   island `island_members` knows (exit 2 = a failed probe, never "nothing to do"). The
   board-sweep's ISLAND column is the positive control: an island issue the selector misses
   either carries a lifecycle label / an `intake:` ruling, or the table has a hole — fix the table
   by PR, never hand-rule around it. Issues no island claims go to the report's `none` list; two
   sightings of one shape = a new island row.
3. **Add the text inputs** — tracker items whose **Next:** is mechanical (decided, bounded; no
   window, mint, ruling or measurement) become `text:` inputs (`source: FU-NNN`) of their island's
   sitting, which `file`s and rules them; the seat then points the FU line at the issue (the
   tracker's single writer). Meta-state bullets of the same shape likewise.
4. **Dispatch** — one `mode: apply` sitting per island/part, in parallel, background. The dispatch
   prompt carries only: read `agents/jail-subagent-card.md`, then `gateway/intake.md` in full, then
   `docs/intake/<island>.md` (in place of §Island facts; the gateway uses its own block); the
   inputs; the board-sweep report path as a DRAFT to re-verify, never to replay; the report path
   (scratchpad, island-named).
5. **Collect** — each report (table + bodies + **Facts I lacked**). `deferred (cap)` inputs go to
   one more sitting. A lacked fact that recurs across sittings is a facts-file edit (PR); a rule
   gap is a GAPS entry here.
6. **Report** — to the operator only: the `seat` rulings grouped by the ONE ruling that unblocks
   them (one ruling often clears several), the Goal verdicts owed, the human-filed close
   candidates. Counts for the rest. A TICK-LOG entry (condition → command) is the next pass's
   watermark.

## Pipeline

[`board-sweep`](../board-sweep/SKILL.md) → **intake** → [`fu-sweep`](../fu-sweep/SKILL.md) (the
non-mechanical remainder) → [`docs-cleanup`](../docs-cleanup/SKILL.md). The docs comb fans out by
island the same way: one fact-check subagent per island's owning docs, each in its own clone with
its own PR; the tracker/ADR corrections they find come back to the seat.

## Graduation

The daily [`island-intake`](../../../agents/coordinator/island-intake-argo.yaml) CronWorkflow runs
the gateway on the dig source. Wiring the issue pile and the other islands into it is the
operator's ruling (spike §Open questions 1, 5); this skill is the hand-run until then, and its
reports are the evidence (days from filing to `agent/queued`; `seat` rulings the operator answers
with "decidable from the island's text").
