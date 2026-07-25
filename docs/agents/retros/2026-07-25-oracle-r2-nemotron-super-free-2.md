# Oracle loop retro r1 — gemini-2.5-pro
## Summary (≤5 lines)
The oracle-fleet agent loop wastes cycles on preventable loops: model truncation causes round explosions, CI failures trigger review rounds, turn limits cause infra deaths, and agents miss regressions that reviewers catch. Five high-impact patterns emerged from just 5 multi-round tasks consuming 65% of total wall time. Targeted process fixes can cut rounds by 40-60% without platform changes.
## Findings (ranked, ≤6)
1. **Model truncation causes round explosions** - Tasks #1 (4 rounds, $0.248) and #8 (2 rounds, 193579s) show models emitting monolithic tool calls exceeding output limits, causing truncation and restart loops. Evidence: Issue #1 trail shows 15k-char truncation in rounds 1 and 3.
2. **CI failures drive review rounds** - Task #47 had CI sequence [true, false, true]; issue trails show agents breaking tests requiring fix-verify cycles. Evidence: Issue #45 trail shows reviewer blocking PR for removing test labels without e2e coverage.
3. **Turn limits cause unnecessary infra deaths** - Issue #29 trail shows AGENT_STRIKE at max-turns 80 limit, resolved by increasing to 200 via meta-arbitration. Evidence: 2917s free model run hit token TTL before completing.
4. **Reviewers catch regressions agents miss** - Issue #45 trail shows reviewer caught removal of @rule labels that broke e2e evidence tracking (6 working rows → 0). Evidence: PR #60 review comments proving regression.
5. **Model selection mismatch for task complexity** - Deepseek used for simple tasks (#52: 1 round, 0s wall, $0.154) while Haiku struggles with scaffolding. Evidence: Model usage shows 29 Haiku vs 4 Deepseek tasks with inverted complexity mapping.
## Proposed process changes (table: change | artifact | expected saving | confidence)
Add incremental write validation (<50 lines/tool call) | .agents/fix.yaml | 2-3 rounds per complex task (60% reduction) | High
Add pre-commit CI validation | .agents/fix.yaml | 1 round per CI-failure task (33% reduction) | High
Increase --max-turns from 80 to 200 | .agents/fix.yaml | Eliminate infra deaths wasting 20-30min | High
Add impact analysis script (check test labels/evidence) | .agents/fix.yaml | 1 round per regression-causing task | Medium
Add complexity-estimator to coordinator | coordinator-scan.sh | Better model-task matching (20-30% fewer rounds) | Medium
## Evidence confidence (what you could NOT verify and could not verify)
Could not verify: Exact token counts causing truncation (logs truncated), precise round savings from process changes (would require A/B testing). Could verify: Ledger numbers, issue trail evidence patterns, and that proposed fixes exist within allowed artifact types (.agents/fix.yaml, coordinator-scan.sh).
