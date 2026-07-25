# Oracle loop retro r1 — gpt-4o
## Summary (≤5 lines)
- 32 tasks in ledger (ranks 1-32); 4 rounds max, 2.2 avg; **zero reviewer rounds recorded** despite 3+ review cycles on #1, #8, #45, #47
- Deep infrastructure strikes (token TTL, budget-403, turn-cap, ConnectionRefused) consumed **0 rounds but hours of wall-time** — especially on scaffold tasks (#1, #29, #43, #42, #52)
- Haiku model dominates (31/32 tasks); **calibration_error = 0.000 everywhere** because estimator was never exercised (cost tracking broken for haiku, deepseek estimates 5-6× actual)
- Reviewer non-convergence on CITE-invariant: **#1 burned 3 review rounds** finding new `build_provision_response` violations each time; **#7** reviewer found new bug after fix
- WIP=1 slot + shared-file conflicts (pyproject.toml, chart/) serialize lanes; ingest tasks (#116-125) block queue for hours
- **One process change per finding below** — all target `.agents/fix.yaml`, reviewer rubric, or coordinator preflight

## Findings (ranked, ≤6)

### 1. Model truncation ceiling (max_tokens=4096) killed scaffold rounds — fixed by proxy floor, but not verified for haiku/claude
**Evidence**: #1 round 1 (deepseek): 15,267-char tool call → goose `-32602 EOF`; #1 round 3 (deepseek): 14,781-char → same; #7 round 1 (deepseek): degenerate revert/RED loop from same ceiling. Meta-coordinator confirmed: "all three cut off at ~14781/15267/16322 chars ≈ ~4k tokens — a `max_tokens=4096` default". Fix deployed in egress proxy (floor 16384) **after** #1 round 3 but **before** #1 re-test; #1 round 4 succeeded.
**Mechanism**: The goose→OpenRouter path hard-capped completions at 4096 tokens. Any single file write >~4k tokens (common in scaffold tasks) truncated mid-write, leaving corrupt state. Recipe's "write incrementally ≲50 lines" instruction cannot bind a config ceiling.
**Process change**: In `.agents/fix.yaml` add `model_settings.max_tokens: 16384` under `settings` and a preflight check `goose --version && goose doctor | grep -q max_tokens` in the CI gate. This makes the floor explicit in the recipe, not just the proxy.
**Expected saving**: Eliminates 100% of truncation strikes on scaffold tasks (observed: 3 strikes on #1+#7). Saves ~15 min wall-time per strike (pod spin-up + re-clone).

### 2. Claude/haiku 80-turn cap burned 6 worker rounds across 5 tasks — fixed by coordinator flag, not recipe
**Evidence**: #29 r1 (haiku): "Reached max turns (80)"; #43 r1 (haiku): same; #42 r1 (haiku): same; #52 r1 (haiku): same; #22 r1 (haiku): "completed cleanly... launcher logged 'no PR opened' because claude harness has no agent-finalize". Coordinator arbitration raised cap to 200 via `--max-turns` flag; subsequent re-dispatches succeeded. Ledger shows these as `rounds=1` with `wall_time_s=0` — **infra strikes invisible in ledger**.
**Mechanism**: The claude/haiku subscription tier enforces a per-session turn limit (80) that the worker hits on multi-file edits. The cap is a coordinator launch flag, not a model property, so `.agents/fix.yaml` cannot enforce it.
**Process change**: In `.agents/fix.yaml` add `settings.goose_max_turns: 200` and extend the developer extension invocation to pass `--max-turns ${goose_max_turns}`. Document in `docs/process/conventions.md` that scaffold tasks MUST request this tier.
**Expected saving**: 6 rounds × ~30 min = ~3 hrs wall-time recovered across this run; prevents future silent strikes on any task >60 turns.

### 3. Infra strikes (token TTL, budget-403, ConnectionRefused, subscription capacity) consume 0 rounds but hours of wall-time
**Evidence**: #1: 3 infra strikes (token-expiry 2917s > 60min TTL; budget-403 pace/budget; auth-401 storm FU-021) before first logic round — **13,762s wall-time, $0.248 cost, 0 rounds consumed**. #29: 2 infra strikes (turn-cap + coordinator race). #47: 4 coordinator blocks over 4 days (chart/ policy conflict), 0 rounds. #52: ConnectionRefused + TOCTOU double-dispatch. #125: WIP=1 slot held by unrelated retro pod → deferred. Ledger `wall_time_s=0` for all haiku tasks — **wall-time tracking is broken**.
**Mechanism**: The coordinator treats infra deaths as "no round consumed" and re-dispatches same round, but wall-clock accumulates. Token TTL (60 min) < free-model pace (hy3:free 2917s); budget estimator ($0.30) < actual spend ($0.51); subscription capacity (max 3 pods) < concurrent lanes. No circuit-breaker aggregates these into "pause and fix platform".
**Process change**: Add `coordinator_preflight` section to `.agents/fix.yaml` with: `token_ttl_min: 120`, `min_pace_s: 300`, `subscription_slots: 3`, and a `circuit_breaker` clause: "if 2+ infra strikes in 1h on same issue → label `agent/platform-blocked`, page human". Also fix wall-time capture: mandate `AGENT_RUN_STATS` include `wall_time_s` from pod start.
**Expected saving**: #1 alone lost 3.8 hrs to infra; with preflight pace check, hy3:free would be skipped for scaffold tasks → save ~3 hrs/task. Circuit breaker prevents retry storms (e.g., #125 WIP contention).

### 4. Reviewer non-convergence on CITE-invariant — point-fixing same function burns review rounds
**Evidence**: #1: 3 review rounds (22:09, 01:04, 02:20) each finding **new** `build_provision_response` violation: r1: single-lõige `(n)` prefix + null loige; r2: all-points lõige dropped + intro-less duplicate; r3: sibling path duplicate + alampunkt-only ambiguity. Human post-mortem: "three rounds of point-fixes haven't converged because `build_provision_response`'s text-assembly is being patched case-by-case against an under-specified invariant". #7: reviewer found new duplication bug after worker claimed fix. Ledger shows `reviewer_rounds=0` for all tasks — **review rounds invisible**.
**Mechanism**: The reviewer (haiku, temp 0.0) executes the engine against constructed fixtures and finds invariant violations the test matrix misses. The worker fixes the specific repro but misses isomorphic paths (sibling branches, whole-§ vs single-lõige). The spec `RT-STATUTE-PROVISION` is judgment-flagged (⚖) but under-specified for all-points lõige and recurring alampunkt shapes.
**Process change**: In `.agents/review.md` add a **convergence clause**: "If 2+ review rounds return CHANGES_REQUESTED on the same function/file family, the reviewer MUST in round 3 emit a `REFACTOR_REQUIRED` verdict with a concrete structural rewrite spec (not a point fix). The worker then gets one round to implement the rewrite." Also add `max_review_rounds: 3` (already present) but make it a hard gate to `agent/blocked`.
**Expected saving**: #1 would have stopped at round 2 (2 review rounds → refactor spec) instead of round 3 → save 1 review round + 1 worker round = ~45 min. Prevents infinite whack-a-mole on complex invariants.

### 5. Reviewer rounds missing from ledger — `reviewer_rounds` always 0 despite 3+ actual rounds
**Evidence**: Ledger: all 32 tasks show `reviewer_rounds: 0`. Reality: #1 had 3 review rounds (comments at 22:09, 01:04, 02:20); #8 had 1 review round (coordinator arbitration comment); #45 had 2 review rounds (coordinator comments "round 2", "round 2 fix landed"); #47 had multiple review cycles; #123 had 2 review rounds. The `ci_sequence` shows `[true, true, true]` for 3-round tasks but `reviewer_rounds` doesn't increment.
**Mechanism**: The ledger schema treats `rounds` as worker dispatches only. Review cycles that return CHANGES_REQUESTED and trigger a new worker dispatch are counted as another `round` but `reviewer_rounds` is never populated. The coordinator comments use "round N" for worker dispatches, not review cycles.
**Process change**: In the coordinator's ledger-writer (not in this repo — but we can mandate the field), require `reviewer_rounds` = count of distinct reviewer verdicts (CHANGES_REQUESTED or APPROVED) per task. As a local fix, add to `.agents/fix.yaml` under `review`: `track_rounds: true` and a post-merge hook that increments a `review_rounds` counter in the issue labels (e.g., `agent/review-rounds=3`).
**Expected saving**: Enables retro analysis of review efficiency. Currently impossible to distinguish "3 worker rounds due to CI failures" from "3 worker rounds due to reviewer churn". This finding alone unlocks future savings.

### 6. Budget estimator uncalibrated — `calibration_error=0.000` because haiku cost=$0 and deepseek estimate 5-6× actual
**Evidence**: 30 md-tier tasks show `budget_cap_usd: 1.0`, `total_cost_usd: 0.0`, `calibration_error: 0.0`. #1 (deepseek, xs tier): `budget_cap_usd: 0.25`, `total_cost_usd: 0.248`, `calibration_error: null`. Deepseek actual run costs: $0.063, $0.0596, $0.0472 (r1-r3) vs estimator $0.1633 (est) / $0.3024 (est for earlier attempt). Estimator overestimates 3-6×. Haiku cost tracking returns $0 (subscription tier, no per-token billing) → calibration_error = log(0/1) = undefined → stored as 0.0.
**Mechanism**: The budget estimator uses registry list prices (e.g., $0.0302/M for deepseek) but actual spend depends on token count, which varies wildly by task type (scaffold vs fix). Haiku is a flat-rate subscription — no per-call cost emitted → estimator assumes 0 → division by zero guarded as 0.0.
**Process change**: In `.agents/fix.yaml` under `budget_tiers.md`, add `cost_model: "subscription"` for haiku and `cost_model: "per_token"` for deepseek. For subscription models, track `effective_cost_usd = subscription_monthly_usd / estimated_runs_per_month` and emit in `AGENT_RUN_STATS`. For per-token, calibrate estimator against last 10 runs: `estimated = median(actual) * 1.2`.
**Expected saving**: Prevents over-provisioning budget caps (deepseek capped at $0.25 but only needs ~$0.06) and under-detection of haiku runaway (if subscription exhausted). Accurate calibration enables cost-based model routing (currently broken).

## Proposed process changes (table: change | artifact | expected saving | confidence)

| Change | Artifact | Expected saving | Confidence |
|--------|----------|-----------------|------------|
| Add `max_tokens: 16384` + preflight check | `.agents/fix.yaml` (settings + CI gate) | 3 truncation strikes/run × 15 min = **45 min/task** on scaffold tasks | 0.95 (root-caused, fix deployed, needs recipe pin) |
| Add `goose_max_turns: 200` + pass to developer ext | `.agents/fix.yaml` | 6 turn-cap strikes observed × 30 min = **3 hrs/run** | 0.9 (coordinator flag proven, needs recipe integration) |
| Add coordinator preflight (pace, TTL, slots) + circuit breaker | `.agents/fix.yaml` (new `coordinator_preflight` section) | #1 lost 3.8 hrs; #125 deferred 1+ hr → **~5 hrs/run** on platform-constrained tasks | 0.8 (requires coordinator change; recipe can declare requirements) |
| Add reviewer convergence clause (REFACTOR_REQUIRED at round 3) | `.agents/review.md` | #1: 1 review + 1 worker round = **~45 min**; prevents unbounded whack-a-mole | 0.85 (pattern clear; human gate on rewrite spec) |
| Mandate `reviewer_rounds` in ledger + label tracking | `.agents/fix.yaml` (review.track_rounds) + coordinator | Enables future retros; **unlocks all downstream savings** | 0.9 (schema change only; coordinator must implement) |
| Split cost_model (subscription vs per_token) + calibrate on rolling median | `.agents/fix.yaml` (budget_tiers) | Fixes broken calibration; enables cost-based routing → **~30% cost reduction** on model selection | 0.7 (requires telemetry pipeline; haiku subscription cost opaque) |

## Evidence confidence (what you could NOT verify and why)

- **Reviewer verdict details for tasks #2-#30**: Ledger shows 3 rounds, all CI green, but issue comments only have 1-3 coordinator comments (no reviewer bot comments visible). The `homelab-reviewer[bot]` comments may have been deleted or are on PRs not linked in issue comments. Cannot confirm if review rounds happened or workers self-corrected.
- **Actual haiku cost per run**: Subscription tier — no per-call billing exposed. `AGENT_RUN_STATS` shows `cost_unknown: true` for #22. Cannot calibrate without provider API.
- **Wall-time for haiku tasks**: All `wall_time_s: 0` in ledger. Pod logs not retained; `AGENT_RUN_STATS` missing `wall_time_s` field for haiku runs. Cannot verify if 0 means "fast" or "untracked".
- **Retry storms**: Ledger shows `retry_storms: 0` for all tasks. FU-021 auth-401 storm on #1 round 3 was classified as infra strike, not retry storm. Definition of "retry storm" may exclude infra-level retries.
- **Deepseek calibration**: Only 1 task (#1) used deepseek in ledger; 3 runs with costs $0.047-0.063 vs estimates $0.16-0.30. Sample size too small for statistical confidence.
- **WIP limit contention**: #125 deferred due to "retro cross-review pod" holding slot — cannot verify if this pod was legitimate or a leak; no pod list in ledger.
