# Oracle loop retro r1 — goose
## Summary (≤5 lines)
Analysis of 32 tasks revealed three costly patterns: extreme wall-time outliers, CI skipping on worker failure, and worker exit codes not reflecting task completion. These patterns caused unnecessary rounds and delays.
## Findings (ranked, ≤6)
1. Wall-time outliers: Tasks like #1 and #8 consumed excessive time (hours to days) per round due to missing timeouts.
   Evidence: issue #1: 13762s (4 rounds), issue #8: 193579s (2 rounds)
   Mechanism: No per-round timeout allows infinite loops or long computations to consume excessive resources
   Process change: Add per-round timeout of 3600s in .agents/fix.yaml
   Expected saving: ~55 hours saved for outlier tasks (based on #8 saving ~53.8h plus partial savings for others)

2. CI skipped on worker failure: No CI feedback when worker fails, delaying issue resolution.
   Evidence: issue #29: ci_sequence [null, null] despite worker_exits ["failed", "failed"]
   Mechanism: CI runner skips execution when worker exits non-zero, removing feedback loop
   Process change: Modify coordinator-scan.sh to run CI regardless of worker exit status
   Expected saving: 1 round saved per affected task (e.g., #29 from 2→1 rounds)

3. Worker exit code mismatch: Worker reports success (exit 0) but task remains blocked.
   Evidence: issue #1: worker_exits all "0" but terminal_label "agent/blocked"
   Mechanism: Worker exit code does not enforce task completion criteria, leading to unnecessary rounds
   Process change: Update .agents/fix.yaml to require task completion checks before exiting 0
   Expected saving: 3 rounds saved per affected task (e.g., #1 from 4→1 rounds)
## Proposed process changes (table: change | artifact | expected saving | confidence)
| Add per-round timeout of 3600s | .agents/fix.yaml | ~55 hours saved for outlier tasks | High |
| Run CI on worker failure | coordinator-scan.sh | 1 round saved per affected task | Medium |
| Require task completion before exit 0 | .agents/fix.yaml | 3 rounds saved per affected task | High |
## Evidence confidence (what you could NOT verify and why)
Could not verify exact root cause of wall-time outliers (infinite loop vs heavy computation) without worker logs. Could not confirm if CI skipping is intentional without reviewing coordinator-scan.sh source. Inferred worker exit meaning from ledger fields and terminal labels due to no access to worker implementation.
