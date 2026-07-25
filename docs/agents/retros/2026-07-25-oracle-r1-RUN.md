# Retro run 1 — oracle stack, multi-model pilot (FU-058, 2026-07-25)

First FU-058 retro AND first multi-large-model tryout (operator-directed). Two rides, one
identical brief (full 32-row pain-ranked ledger inline + gh drill-down permission + strict
output contract), hand-supervised from the meta session:

| ride | harness | model | key | outcome |
|---|---|---|---|---|
| A | goose | nvidia/nemotron-3-ultra-550b-a55b:free | ephemeral only-free ($0.01) | report delivered, $0.00; key cap hit post-report (budget-403) |
| B | claude | opus (subscription) | proxy ref, FU-088 latch | report delivered, 259s / 17 turns / 38k out |

**Selection (meta + operator supervision): the opus report** — mechanisms verified against
real artifacts (file:line cites, incident sequences); changes anchored in components that
exist. Nemotron delivered two real catches (reviewer_rounds=0 ledger blindness; truncation
economics) but anchored fixes to invented artifacts (goose `pre_tool_hook`; "the scan writes
the ledger" — it's ledger.py). Cross-review: nemotron critiques the opus report (next file).

Mechanism notes for run 2: the finalize classifier stamped the claude ride
`error_class=goose-32602-truncation` (claude-harness classification gap); the free-key $0.01
cap can 403 mid-finalize on :free rides — mint 0.05 for report-length tasks.

## Cross-review outcome (final): nemotron FAILED the review shape, 3 attempts

| attempt | harness | duration | outcome |
|---|---|---|---|
| 1 | goose | 32s | explored 3-4 turns, ended "clean" with no review |
| 2 | goose (contract-first brief) | 25s | same early-bail |
| 3 | opencode | ~35min | spent the wall on devbox bring-up; killed at the tick boundary — it was holding oracle-fleet's WIP=1 slot against the queued #125 corpus fix |

**Pilot conclusions** (feed FU-095):
1. nemotron-3-ultra:free held a 7.5-min GENERATIVE task (report delivered, decent) but bails
   in seconds on the review-of-a-report shape — task-class-dependent reliability is real and
   measurable; exactly the FU-095(a) task-class axis.
2. Opus report >> nemotron report on artifact grounding (verified file:line cites vs invented
   APIs) — the dual-model value here was the COMPARISON, not the redundancy.
3. Mechanism frictions for run 2: retro rides hold the stack's fixer WIP=1 slot (run them in
   the <stack>-agents ns or off-peak); free-key caps can 403 mid-finalize ($0.05 floor);
   the finalize classifier mislabels claude rides with goose error classes; ride bring-up
   (per-pod devbox closure) can dwarf task time — the FU-015 warm-store lesson applies to
   agent-base too.
4. Run-2 cross-review candidates: a different large free model (e.g. kimi-k3:free) or
   subscription haiku as the critic; nemotron stays report-side only.

## Run 2 addendum (same day): 8-model bake-off + reliable cross-review — see r2-VERDICT.md

All seats delivered (deepseek-v4-pro, hy3, kimi-k3, mimo-v2.5, gpt-oss-120b, nemotron ultra+super
:free; opus r1 as baseline). Total API spend ≈ $1.35. Cross-review finally landed: deepseek-v4-pro
(the rank-2 grounder) reviewed the opus report with per-finding verified verdicts — including a
real catch (stale `specs/TRACKS.md` path; the file moved to `docs/process/` in fleet#104).
Ops lessons this run: GOOSE_MAX_TOKENS=16384 cures the -32602 truncation class (mimo proven);
ride pods must self-clean (the bulk-tier scheduling-cap incident — janitor grace now 30min);
models misstate their own identity in report headers — score by ride, never by header.
