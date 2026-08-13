# Subagent handover misses — the decomposition-rules ledger

**Status: OPEN experiment (operator directive, 2026-08-13).** The jail's build mode during the
bootstrap is **subagent chunks, double-reviewed** — the seat reads the worktree diff pre-push,
then the review reflex reads the PR — and this file is the miss ledger both reads feed: every
defect logged by WHO CAUGHT IT, every catch distilled into a **decomposition rule** for the next
handover. The operator's framing: *"the main thread should keep a log of misses — only way we can
improve the process of handing over work. This is a decomposition rules gathering exercise."*

Companions: the worktree A/B protocol (meta-state §NEXT SESSION, 2026-08-12 — the corpus
question: do corpus-less subagents leak context-poverty defects that surface post-merge?) and the
build-mode section of [`../agents/chainless-redesign.md`](../agents/chainless-redesign.md)
(ADR-107). What settles the experiment: enough rows that the catch-point distribution and the
rule list stabilize — then the seat gate narrows to first-of-family chunks (or drops), the rules
become the dispatch-prompt template, and this spike is harvested into the charter's build-mode
section.

## Why both reviews, for now

The bot proved itself on seat-authored work (4 real round-1 catches across 2 days, two of them in
fable-authored code — PR#407, #412 — both by tool-grounded verification). But the bot has never
been the guard against the A/B's dangerous class: context-poverty defects that pass BOTH reviews
and surface later. Until the post-merge column has data, the seat read stays on every chunk.

## The ledger

One row per PR. `author` = seat (baseline arm) | subagent (trial arm). Catch-points: **seat**
(pre-push diff read) · **bot** (review reflex) · **post-merge** (anything found after — the
lagged column; back-fill it when a defect traces to a merged PR). `rule` = the decomposition/
handover lesson, or `—` if clean.

| date | PR | chunk | author | seat caught | bot caught | post-merge | rule derived |
|---|---|---|---|---|---|---|---|
| 2026-08-12 | #392 | goal-ancestor table-mode (4 fixtures) | subagent | 0 | 0 | (watching) | run-1 of the A/B; 148.5k tokens, 9m11s authoring |
| 2026-08-13 | #407 | claude-ride `--model` fix | seat | — | 1 (fallback pattern tested the PRE-parse shape — could never match) | — | verify a guard's predicate against the value AT THE GUARD, not at the source; the reviewer RAN the parser — decompositions should name the executable check, not just the intent |
| 2026-08-13 | #408 | /route urgency+labels leg | seat | — | 0 | (soaking) | — |
| 2026-08-13 | #409 | model-splitting shim + claude-go | seat | — | 0 | compat gaps found by LIVE probing same day (not review-catchable — no key existed at review time) | probes > reviews for external-API contracts; a chunk against an unprobed API should budget a probe round, not assume the docs |
| 2026-08-13 | #410 | claude-go env file + Go-leg hardening | seat | — | 0 | — | — |
| 2026-08-13 | #411 | ADR-107 charter docs | seat | — | 0 | — | — |
| 2026-08-13 | #412 | pr-wait primitive | seat | — | 1 (reviewDecision survives pushes — the primary caller loop echoed stale feedback; reviewer cited `reviewable_again` as prior art) | — | when a chunk's contract IS a loop, hand over the loop's re-entry case explicitly ("what does the second invocation see?"); state-freshness guards are a named repo pattern — point the author at `reviewable_again` |

## Standing observations (promote to rules as they recur)

- **The seat's baseline bot-catch rate is 2/6 on one day** — the seat's own authoring leaks
  round-1 findings at a measurable rate, which is the honest yardstick for judging subagent rows
  (a subagent arm with 1-in-3 bot catches is not automatically worse than the seat).
- Both seat-arm catches were **contract/state-freshness classes, found by executing the code
  against the live surface** — the tool-grounded-verification mechanism from the banked
  tier-thesis (TICK-LOG 2026-08-13). Decomposition corollary: a handover should always name the
  executable verification ("run X, expect Y"), because that is what reviews demonstrably use.
- Dispatch-prompt mechanics proven so far: warm devbox = `cp -a /workspace/homelab/.devbox .`
  (40s → 3.6s, measured); the PR cycle = `devbox run pr-wait -- <n>` (typed exits; fix-in-context
  on 2, escalate on 3/4/5); worktree per subagent; width ≤2–3 (subscription burn).
