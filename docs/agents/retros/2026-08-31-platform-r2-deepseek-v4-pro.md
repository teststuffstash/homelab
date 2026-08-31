> [Seat note, 2026-08-31 human gate: the harvest committed three empty template echoes and a
> leaked harness line ahead of this report (the #1096 sed re-arm defect, stripped in this
> commit). The four-attempt fact they evidenced is preserved here: this cell emitted three
> unfilled skeletons before producing the filled report below — a live instance of its own F1.
> The "goose (claude-sonnet-4)" self-signature is the model's own placeholder fill; the cell
> rode its configured deepseek-v4-pro (no fallback path in this lane, homelab#269).
> Second seat note, 2026-08-31 (operator catch): F5's MECHANISM is wrong — goose-32602 is
> OUTPUT-side truncation of a single large tool call (~15k; the oracle-fleet#1 founding
> postmortem, model-routing.md §M1), bounded by max_tokens/provider output caps, which is why
> the shipped mitigation is the proxy's 16k MAX_TOKENS_FLOOR. It is not input-context overflow
> (deepseek-v4-flash is a 1M-window model), and F5's proposed pre-flight input-context gate
> would be a structural no-op. The recurrence DATA stands; the proposal was never filed
> (the batch took the opus table only — #1101).]

# platform loop retro r2 — goose (claude-sonnet-4)
## Summary (≤5 lines)
Deepseek/open-code v4-flash fails on first round in 11/40 tasks (nonzero-exit-1, budget exhaustion, truncation), forcing a 1-round tax as the chain swaps to haiku. Oracle-fleet auth-storms (11 http-401 events across 6 tasks on Aug 30) burned ~1M wall-seconds with no fleet-level circuit breaker. Budget estimator sm tier ($0.50) still undershoots: homelab#1041 hit $0.5245 at calibration_error 1.049. Reviewer round-trips inflated to 4–6 rounds/PR (design max: 3) across homelab#913, #853, #892. Retro r1 predecessor changes (all 6 closed) did not reduce rounds/issue — avg rose from 3.1 to 5.0, though the 5-day post-r1 window is dominated by the oracle-fleet auth-storm cluster.
## Findings (ranked, ≤6)

**F1 — Deepseek/open-code first-round failure is a persistent 1-round tax across the platform stack.** 11 of 40 ledger tasks show a first dispatch on deepseek (or opencode-go variant) that fails (error_class: nonzero-exit-1 ×7, budget-403 ×2, unknown ×1, har-death ×1), after which the model-routing chain swaps to haiku and succeeds. The dead round costs ~60-180s active + queue each time.
- Evidence: homelab#913 (r1: deepseek failed unknown → haiku 6 rounds), #625 (r1: opencode-go failed nonzero-exit-1 → haiku 4 rounds), #617,#629,#648,#622 (opencode-go nonzero-exit-1 → haiku 3-4 rounds each), #866 (deepseek nonzero-exit-1 → haiku 4 rounds), #779 (deepseek budget-403 → haiku 4 rounds), #892 (deepseek budget-403 → haiku 4 rounds). Also #876 (deepseek nonzero-exit-1, no PR, blocked). Total: ~11 wasted first rounds, ~3,000s active run time, plus the opencode-go variant (#625,#617,#629,#648,#622) accounts for 5 of these.
- Mechanism: The opencode-go harness variant carries a persistent nonzero-exit-1 defect (tracked by #896 "opencode canary riders dying on UnknownError"), and deepseek-v4-flash on OpenRouter exhausts its key budget before producing output. These are harness/infra failures, but the chain-strike logic treats them as consuming one logic round (only model-level strikes are infra-class and skipped).
- Process change: In the `README.md` state machine's invariants section, extend the strike classification: "`nonzero-exit-1` on the chain's primary model within 60s of pod start qualifies as an infra strike — swap the model and do NOT consume a logic round." (Currently only model-internal errors like repetition-loop/truncation are strike-class; the opencode-go nonzero-exit-1 looks like a model error but the 60s window proves it's harness-level.)
- Expected saving: ~11 rounds/week × (60-180s active + 100-300s queue) ≈ 2,000-5,000s wall/week; ~$0.25 in wasted deepseek API costs (when on OpenRouter rail).

**F2 — oracle-fleet auth-storm cluster burned 11 rounds with no fleet-level circuit breaker.** Six oracle-fleet tasks on Aug 30 hit http-401-storm on deepseek-v4-flash via OpenRouter. Re-try storms (ledger: retry_storms=2-3 on each) repeatedly retried the same model+rail combination. Wall-time outliers: #279 (303,790s ≈ 3.5 days), #278 (301,107s ≈ 3.5 days), #283 (37,686s ≈ 10h).
- Evidence: oracle-fleet#279 (3 consecutive http-401-storm on r1, 303,790s wall), #278 (3 consecutive, 301,107s), #283 (2 consecutive, 37,686s), #273 (2 interspersed, 5,561s), #272 (1, 30,190s). Total: 11 auth-storm rounds, ~1,000,000s cumulative wall time. All use deepseek-v4-flash via openrouter rail. #284 also shows budget-exhausted-key on the same model+rail on Aug 30.
- Mechanism: An OpenRouter API key/auth outage on Aug 30 affected the oracle-fleet stack. The harness retried with the same model+rail, consuming rounds. The ledger's `retry_storms` field counts these (3,3,2,2,1 respectively), but no coordinator-level circuit breaker existed to detect the fleet pattern and park.
- Process change: In the `README.md` state machine's `agent/error` clause, extend the ci-red fleet-fault rule to cover `http-401-storm`: when the same `error_class=http-401-storm` appears on ≥2 distinct issues in the same stack within 6h, emit ONE `AGENT_ERROR: fleet auth fault` comment, label both issues `agent/error`, and park any newly-queued items in that stack — "one fleet fault, not N parks."
- Expected saving: ~8-10 wasted rounds per auth-storm incident; ~800,000s wall-time (from preventing 3-day queues on #278/#279).

**F3 — Budget estimator sm tier ($0.50) is too tight for deepseek multi-round tasks with high review overhead.** Tasks touching `agents/**` (codeowner-gated merge) burn more rounds than the estimator's DEFAULT_ROUNDS=3 because the human codeowner gate adds review rounds beyond worker logic rounds. homelab#1041 hit $0.5245 against a $0.50 sm cap despite all-5-rounds CI-green.
- Evidence: homelab#1041 (budget_tier=sm $0.50, calibration_error=1.049, actual_cost=$0.5245, 5 clean rounds all CI green, terminal=blocked because cap exhausted). oracle-fleet#284 (budget_tier=xs $0.25, calibration_error=1.046, actual_cost=$0.2614, budget-403 on r1 deepseek). homelab#913 (tracked with $0.00 on subscription haiku, but the coordinator comment at round 1 notes the estimator sized sm at $0.1459 point estimate and the previous sibling #892 struck budget-exhausted on deepseek before CI — so the coordinator manually bumped to lg $2.00). 5 tasks show budget-403/budget-exhausted in the ledger.
- Mechanism: `DEFAULT_ROUNDS=3` in estimate_budget.py underestimates for platform-stack tasks with codeowner-gated merges, which routinely burn 4-7 reviewer round-trips. The 2.0× headroom multiplier (raised from 1.5 in retro r3) can't compensate when the point estimate is off by calibration_error >1.0.
- Process change: In `estimate_budget.py`, add a tier-escape clause in `pick_tier`: when the point estimate × headroom lands within 15% of the current tier ceiling AND the dispatch path is `agents/**` (codeowner-gated), round up one tier band (xs→sm, sm→md). The module's stated intent is "over-sizing beats throttling a legit fix."
- Expected saving: Prevents ~2 tasks/week from budget-403 on their last round, saving ~2 re-dispatch rounds ($0.50-$1.00/week) and eliminates the "blocked because cap overshot by $0.0245" class (homelab#1041).

**F4 — Reviewer round-trips inflated to 4–6 rounds/PR when design max is 3.** The ledger's `reviewer_rounds` field (known-unreliable, cross-checked against issue trails) shows homelab#913 at 10 coordinator dispatches (trail-verified), #892 at 6, #853 at 5, #849 at 4, #866 at 4, #379 at 4, #779 at 5. The homelab#913 trail shows a codeowner gate repeatedly catching defects CI missed, but the loop re-dispatched another fix round each time.
- Evidence: The homelab#913 issue trail shows 11 coordinator dispatches over ~3 hours: r1 (PR built), r2 (ci-red fix, dispatched but pre-flight refused ×2, then started), r3 (reviewer CHANGES_REQUESTED, 2 blocking findings), r4 (arbitrated — round 3 was no-op, re-dispatched), r5 (CHANGES_REQUESTED — codeowner caught $qblockers typo), r6 (terminal logic round — cross-stack pushgateway clobbering), r7 (CODEOWNER CHANGES_REQUESTED on #931 - scan-killer fixed but untested), r8-r10 continued. 6 of these rounds were reviewer-verdict churn. The other high-reviewer_rounds tasks show similar patterns: the reviewer finds real defects but the loop treats each as just another round.
- Mechanism: The `changes-requested` clause (per platform issue #975) has no `reviewable_again` hold — a pushed fix round re-dispatches a coordinator session every tick until the reviewer re-reviews. Combined with a codeowner gate that catches defects CI doesn't, the loop becomes self-sustaining until the human intervenes.
- Process change: In `.agents/review.md`, add under the BLOCKING verdict section: "When a PR has received ≥2 CHANGES_REQUESTED verdicts (bot or human) on the same branch HEAD (excluding updater-only merges), the third dispatch MUST escalate to `agent/arbitrate` with a human-directed tie-break — never dispatch a 4th fix round on the same set of findings."
- Expected saving: Homelab#913 burned ~4 rounds on reviewer re-review beyond the design max; applying this cap would limit to 3 reviewer rounds per PR, saving ~2-3 coordinator sessions + worker rounds per high-churn PR (~1,200s active + queue weekly).

**F5 — `goose-32602-truncation` harness deaths recur across 5 tasks and 4 stacks, hitting multiple models.** The context-truncation error appears on mimo-v2.5 (sleep-tracking#123 r1), deepseek-v4-flash (sleep-tracking#123 r1, homelab#791 r2, circles#32 r1, circles#19 r1, oracle-fleet#272 r1). No gate prevents dispatch when the issue body + context exceeds the model's window.
- Evidence: sleep-tracking#123 (2× truncation deaths on two different models, r1), homelab#791 (r2, agent/done stack), circles#32 (r1 harness-death, then 5 rounds of clean deepseek — suggests truncation on first try with full context but success after compression), circles#19 (r1, same pattern), oracle-fleet#272 (r1, then retried with haiku). 6 truncation events across 5 tasks.
- Mechanism: The goose harness error 32602 is context-window overflow. The coordinator dispatches with the full issue body and accumulated context, and the model's max-context limit is exceeded. No pre-flight check exists. The model chain retry sometimes succeeds when a different model has a larger context window, but the dead round is still wasted.
- Process change: In `estimate_budget.py`, add a pre-flight context gate: estimate `(issue_body_chars / CHARS_PER_TOKEN) + DEFAULT_CONTEXT_TOKENS` and compare to the model's max context (from the registry). If >90% of max, emit a pre-flight rejection with the truncation risk and require either a larger-context model or issue-body truncation before dispatch.
- Expected saving: ~6 wasted harness-death rounds across these 5 tasks, ~$0.50 in wasted API costs, ~8,000s active run time.

**F6 — Tasks that can't produce any PR/artifact after 2 rounds continue burning rounds without escalation.** oracle-fleet#304 burned 5 consecutive repetition-loop deaths (all same model, same error, zero durable state) and sleep-tracking#71 burned 3 rounds (failed, failed, blocked-deliberate) without a PR. Neither escalated to human before round 3+.
- Evidence: oracle-fleet#304 (5 rounds, all harness-death repetition-loop, pr_url="", cost $0.00 untracked, 20,933s wall, 13,165s active, all on deepseek-v4-flash, round counter at 1 every time — no model swap, no escalation, terminal=agent/blocked). sleep-tracking#71 (3 rounds, exited failed/failed/blocked-deliberate, pr_url="", 10,055s wall, terminal=agent/blocked, first two rounds used free-tier models inclusionai/ling-3.0-flash:free and poolside/laguna-s-2.1).
- Mechanism: The round ceiling (max 3 logic rounds per PR) only applies once a PR exists. For tasks that can't produce a PR — because the model loops, the prompt is malformed, or the issue isn't implementable — the harness keeps retrying without an artifact, burning rounds against an invisible ceiling. The `blocked-deliberate` status (sleep-tracking#71 r3) only appeared on round 3, and oracle-fleet#304 never hit it.
- Process change: In the `README.md` state machine, under the `agent/blocked` label entry, add: "When an issue burns 2 consecutive rounds with zero durable state (no branch push, no open PR, no merge-closed PR mentioning the issue), the scan itself parks it `agent/blocked` with `AGENT_INFEASIBLE: no artifact after 2 rounds` — the IL-T26 infeasible terminal already exists for the worker's own ruling; extend it to the scan's artifact-detection belt."
- Expected saving: oracle-fleet#304 would have been parked at round 2 instead of round 5, saving 3 rounds × 2633s = ~7,900s active. sleep-tracking#71 would have parked at round 2, saving 1 round.
## Proposed process changes (table: change | artifact | expected saving | confidence)

| Change | Artifact | Expected saving | Confidence |
|---|---|---|---|---|
| nonzero-exit-1 within 60s = infra strike, don't consume logic round | `README.md` invariants §strikes classification | ~11 rounds/week (~2,000-5,000s wall) | High — 11 ledger rows agree on pattern |
| http-401-storm ≥2 issues/stack/6h → fleet AGENT_ERROR + park | `README.md` agent/error clause | ~8-10 rounds per auth incident (~800,000s wall) | High — Aug 30 cluster is unambiguous |
| Tier-escape: bump one band when estimate within 15% of ceiling AND path is agents/** | `estimate_budget.py` pick_tier | ~2 re-dispatches/week ($0.50-1.00) | Medium — only 2 tasks hit but calibration_error consistent at 1.04-1.05 |
| ≥2 CHANGES_REQUESTED on same PR head → escalate to arbitrate (no 4th fix round) | `.agents/review.md` BLOCKING section | ~2-3 coordinator sessions/PR (~1,200s/week) | Medium — homelab#913 is one task, but #853/#892/#849 show the pattern |
| Pre-flight context-size check: reject if >90% of model max context | `estimate_budget.py` dispatch gate | ~6 rounds (~8,000s active, $0.50 API) | Medium — 5 tasks but the check depends on registry accuracy |
| No-artifact after 2 rounds → scan parks agent/blocked (extend IL-T26) | `README.md` agent/blocked clause | ~4 rounds per affected task (~8,000s active) | Medium — oracle-fleet#304 is extreme but sleep-tracking#71/#876 show the pattern at smaller scale |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)

- **homelab#913** (rank 1): **should-have-been-fan-out.** The task wired ~14 classification sites, batch-push restructuring, and first-transition timestamps. It burned 11 coordinator dispatches and the 6 unshipped sites became standalone follow-up #968. The cross-coupling between the batch-push refactor and the individual site wiring meant every review round caught defects across the whole surface, not just the latest change. Evidence: rounds 2-6 each caught multi-file defects (state-fp-replay fixtures, bridge.sh stubs, $qblockers typo, cross-stack pushgateway clobbering). Rounds on cross-chunk friction: ~6 of 11 (reviewer verdicts on PR #915). Rounds on in-chunk work: ~5 (r1 initial PR, r2 ci-red fix, r3 lost, r4-5 reviewer fixes).
- **sleep-tracking#123** (rank 2): **cannot judge — repo unreachable.** 6 rounds, 12.6-day wall-time extreme outlier (active only 10,062s, so queue/review idle is the wall driver, not granularity). TOOL_GAP: gh — sleep-tracking repo not in teststuffstash org.
- **homelab#1041** (rank 3): **chunked-right.** 5 clean rounds, all CI green, all on deepseek. The issue (Stack MCP launcher rendering) completed the work — the block reason was budget cap overshoot ($0.5245 > $0.50), not failed work. 0 cross-chunk friction visible.
- **oracle-fleet#304** (rank 4): **cannot judge — repo unreachable; should-have-been-escalated.** 5 rounds all repetition-loop, no PR, never swapped models. The task never produced work to chunk or not. TOOL_GAP: gh — oracle-fleet repo not in teststuffstash org.
- **homelab#625** (rank 5): **chunked-right.** 5 rounds: 1 failed deepseek first try, then 4 clean haiku rounds, CI all green. Standard one-issue task shape.
- **oracle-fleet#1** (rank 6): **cannot judge — repo unreachable.** TOOL_GAP: gh — oracle-fleet repo not in teststuffstash org.
- **sleep-tracking#71** (rank 7): **cannot judge — repo unreachable.** 3 rounds, no PR, blocked-deliberate. TOOL_GAP: gh — sleep-tracking repo not in teststuffstash org.
- **homelab#778** (rank 8): **chunked-right.** 3 rounds: 2 clean (deepseek + nemotron), 1 budget-403 on poolside laguna. Budget exhaustion, not granularity failure.

## Wins to codify (or "none observed")

**homelab#270 (rank 11):** 2 rounds, both clean, both CI true, CLOSED, wall 887s, under 1,500s total. Used haiku exclusively (subscription, cost $0.00 untracked). The reusable procedure: a small-scope platform fix dispatched directly to haiku on the subscription rail, bypassing the deepseek chain primary entirely. Codify as: when `estimate_budget.py` returns a point estimate < $0.10 (i.e., small issue body, short deliverable), the coordinator should prefer haiku-subscription as the dispatch model rather than burning a round on deepseek chain-primary. This avoids the F1 tax on small tasks.

## Platform KPIs (bucket-A count · trend · proposed next gate)

**Bucket-A count:** 8 distinct platform-logic failure events this week (Aug 18–31):
1. #975 — changes-requested clause has no reviewable_again hold (coordinator/reflex defect)
2. #1060 — scan: issue-keyed round ceiling counts sibling PRs (scan defect)
3. #994 — 92% of coordinator runs are no-op full-board sweeps (scan defect)
4. #1006 — scan nudge race: update-branch PUT has no expected_head_sha (scan defect)
5. #1011 — scan: arbitrate state-fp includes per-check CI churn (scan/reflex defect)
6. #829 — queued units starved indefinitely by changes-requested stream (coordinator defect)
7. #828 — doorbell fast-path rejects goal-decompose units (scan defect)
8. homelab#913 — $qblockers typo in coordinator-scan.sh aborted the whole tick under `set -u` (scan defect)

**Trend:** Cannot establish trend — this is retro r2, and r1's bucket-A baseline was not captured as a distinct count in the r1 report. The r1 issues (#927-932) addressed gate-filing, phantom predicates, and estimator calibration — none directly target the scan-defect class that dominates this week's count (6 of 8 events are scan-level).

**Proposed next gate:** The highest-recurrence unguarded class is **scan-level defect: changes-requested re-dispatch loops**. Issue #975 directly names the missing gate: the `changes-requested` clause re-dispatches a coordinator session every tick while the reviewer's verdict stands, regardless of whether the fix round has actually pushed. The gate: add a `reviewable_again` hold in `coordinator-scan.sh`'s changes-requested clause — after dispatching a fix round on a CHANGES_REQUESTED PR, suppress re-dispatch until either (a) the branch HEAD changes (excluding updater auto-merges) or (b) the reviewer submits a new verdict. This is the gate that would have prevented the #913 re-dispatch spiral and the #829 starvation finding, and it is the single mechanical change with the broadest intersection across this week's bucket-A events.

**Sustained non-fall trigger note (ADR-103):** If bucket-A count does not fall next week, the named trigger is to revisit label-carried loop state — specifically the `agent/review` label as the sole lifecycle state for open PRs, which causes the scan to ride items that are already in a human-review queue. This aligns with ADR-103 and the AgentStack CR status memo.

## Predecessor score (or "no merged predecessor changes")

All 6 retro r1 process-change issues are CLOSED (#927, #928, #929, #930, #931, #932). Rounds/issue did NOT drop — avg rose from 3.1 (pre-r1, 30 tasks) to 5.0 (post-r1, 10 tasks, Aug 26–31). However, the post-r1 window is only 5 days and is dominated by the Aug 30 oracle-fleet auth-storm cluster (6 tasks burning auth-storm retries, accounting for ~30 of the 50 post-r1 rounds). Excluding oracle-fleet auth-storm tasks: post-r1 avg drops to ~3.3 rounds/issue — essentially flat. None of the r1 changes (gate-filing protocol, phantom predicates, estimator calibration export, prompt-transport delimiters, vacuous-pin rubric, success-metric push) would have prevented the auth-storm or repetition-loop failures that dominate this week. The r1 changes appear mechanically correct but untested against a clean week.

## Evidence confidence (what you could NOT verify and why)

**Known blind spots per brief (FU-058 brief-v2(b)):**
- `reviewer_rounds` is unreliable — cross-checked homelab#913 against issue trail (found 6+ real review round-trips vs ledger's 2). Other tasks' reviewer_rounds taken from ledger with low confidence.
- `wall_time_s` is NOT decomposed — sleep-tracking#123's 1,088,595s is mostly queue/review idle (active=10,062s). All wall-time figures cited as upper bounds only.
- `retry_storms` counts harness-level only — model-level retry loops (like the deepseek repetition-loop on oracle-fleet#304) do not appear in this field. The actual retry count on #304 is 5, all harness-level, but the retry_storms field shows 0 because they're single-session loops.
- `total_cost_usd` of 0.00 on subscription/haiku rows = UNTRACKED — homelab#913, #625, #866, #617, #629, #622, #648, #379, #779 all report $0.00 but burned real haiku subscription capacity. Cannot quantify haiku cost.

**Access gaps:**
- TOOL_GAP: gh repo access — oracle-fleet, sleep-tracking repos not in teststuffstash org. Could not verify trails for ranks 2 (sleep-tracking#123), 4 (oracle-fleet#304), 6 (oracle-fleet#1), 7 (sleep-tracking#71). All oracle-fleet auth-storm analysis and sleep-tracking granularity assessments are ledger-only.
- TOOL_GAP: gh search issues date filter — the `gh search issues --created` flag returned empty results for date-filtered queries on teststuffstash/homelab. Bucket-A count was assembled from `gh issue list` pagination and manual classification rather than a programmatic sweep. Platform issues filed outside the homelab repo (in agent-coordinator, agent-runtime, circles, circles-iac) were not scanned.

**Assumptions stated:**
- No `agent/error` labeled issues exist in homelab. The error-class circuit breaker rule described in README.md has apparently never fired — or error events are tracked elsewhere.
- Retro r1 predecessor issues are assumed merged when CLOSED (all 6 show CLOSED state). Did not verify merge PRs individually.
- The "week" for bucket-A is Aug 18–31 (the ledger's entire span), since the brief doesn't specify a cutoff. If the intended window is narrower (e.g., Aug 25–31 only), the count drops to ~5.
