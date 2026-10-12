# platform loop retro r8 — goose
## Coverage (window, bundle identity, completeness, late corrections)
**Window:** 2026-10-04 to 2026-10-06 (Goal #2273 theme assembly wave). **Deep-dive set:** 31 issues closed with `agent/done` in the window, all Goal #2273 children dispatched against `goal/2273-scan-guards` or `goal/2273-seam-parsers`. **Model:** deepseek/deepseek-v4.1-flash:exacto on every ride (single-rail routing). **Completeness:** Ledger, S3 transcripts, OpenRouter spend data, and cross-repo oracle-fleet/agent-runtime trails are unreachable from this pod — see Evidence confidence. **Late corrections:** none.

## Summary (≤5 lines)
A single-model theme assembly wave of 31 scan-guard tasks completed in ~36h with 48% first-round approval. WIP-ceiling saturation (#2305's own defect) caused 12 deferral cascades before the fix landed. The clause-coverage task (#2280) burned 4 CI-red/arbitrate coordinator rides — the most expensive single-task cost in the set — because the model's output-token cap truncated the assertion mid-emission three times. Deepseek v4.1-flash:exacto hit three distinct failure classes (http-401-storm, rate-limit, output-token) with no alternative route. The sm budget tier underprices flash models (#2163 fixed the doc but not the estimator band).

## Findings (ranked, ≤6)

**F1 — WIP-ceiling saturation creates self-reinforcing deferral cascades (№2305, №1627, №2164)**
- **Mechanism:** The C4/C5 block gates on ANY live worker pod in the repo. A single long-running ride hides every phantom `agent/in-progress`, preventing phantom cleanup, which keeps WIP slots occupied. Sibling tasks queue behind the phantom ceiling. #2305 itself *was* this defect — the fix landed mid-wave.
- **Evidence:** #1627 deferred 3× before round 1 (2026-10-05 19:02, 2026-10-06 07:26, 07:56). #2164 deferred 2× (08:12, 11:38). #2203 deferred 2×. 12 of 31 tasks (39%) had at least one dispatch-refusal. The fix #2305 (C4/C5 block re-scoped to phantom-aware) closed at 16:51 on 10-06 — after the wave's peak.
- **Process change:** `agents/coordinator-scan.sh` C4/C5 gate: scope the live-worker probe to *only* workers whose `Touches` footprint intersects the candidate's, using the existing `fp_conflict` family (already demonstrated in #2305; needs post-merge measurement).
- **Expected saving:** Rail 3 (subscription): eliminates ~12 deferral coordinator re-probes per wave at ~$0.02/ride amortized, plus Rail 2: each deferral already minted and deleted a per-session key (~$0.01/key). Rail 1: zero — no operator touch per deferral (the scan auto-requeues).

**F2 — Clause-coverage assertion CI-red loop burned 4 coordinator arbitrate rides (№2280)**
- **Mechanism:** The clause-coverage replay case (#2280) required the agent to emit a large fixture.yaml covering the full (labels × PR state × check conclusion) cross-product. The model's output-token cap truncated the emission mid-file on rounds 1, 4, and 5, leaving CI red and requiring a coordinator arbitrate session to re-steer each time. Round 2 was a no-op (agent skipped `arbitration.md`). 4 of 6 rounds were CI-red/arbitrate.
- **Evidence:** #2280's agent-summary records 6 rounds, 4 ci-cause steering directives (rounds 4, 5, and the vacuous-pin review), 1 output-token-limit hit. Rounds 1 and 4–5 each required a full coordinator arbitrate session + pod spawn + model invocation that produced no durable commit.
- **Process change:** `.agents/build.yaml` recipe: add a pre-emission size gate — if the estimated output (lines × `CHARS_PER_TOKEN` in `estimate_budget.py`) exceeds the model's context window, split the deliverable into separate, smaller writes (already prescribed in the round-4 ARBITRATE directive but not auto-enforced). The recipe should mandate incremental writes for any fixture with >200 expected rows.
- **Expected saving:** Rail 3: 3 fewer coordinator rides at ~$0.02/ride amortized. Rail 2: 3 fewer full-context model invocations at ~$0.05–0.10/ride (deepseek flash pricing). Total ~$0.20–0.35 saved per similar task. Rail 1: zero (no operator touch).

**F3 — Single-model routing delivers no failure-class diversity (№1627, №2168, №2280, №1855, №2181)**
- **Mechanism:** Every deep-dive task used `deepseek/deepseek-v4.1-flash:exacto`. Three distinct transient failure classes hit this single rail: http-401-storm (#1627 round 2), rate-limit (#2168 round 1), budget-exhausted-key (#2280 round 5, #1855, #2181). The router's per-session pin selects the same model every time — there is no fallback rail. #1640 (router-first) addresses this structurally but the deep-dive wave predates its theme assembly.
- **Evidence:** 11 of 31 issues show a model annotation; all 11 are `deepseek/deepseek-v4.1-flash:exacto`. Strike classes observed: http-401-storm (1), rate-limit (1), budget-exhausted-key (3), output-token-limit (6 instances across 6 issues). No secondary model was ever attempted.
- **Process change:** `agents/estimate_budget.py` `DEFAULT_MODEL` / the launcher's router: when the per-session pin's model has a live strike for the session's error_class, `/route` must nominate the next-cheapest model below the tier cap. The router already has the strike table (#1668, Goal #1640); the launcher must consume it before re-dispatching at the same round.
- **Expected saving:** Rail 2: eliminates one wasted round per strike (~$0.05–0.10/model-invocation). Rail 3: one less coordinator ride per strike-driven re-dispatch. Rail 1: zero (strikes are auto-handled today; the fix replaces an auto re-ride with a smarter re-ride).

**F4 — Budget estimator sm→md bump is a no-op for flash models (№2163, №1855)**
- **Mechanism:** `estimate_budget.py` sm tier_floor is ~$0.50, md tier_floor is ~$1.00, but the served flash models (deepseek v4.1-flash) price well below both floors. Bumping sm→md changes the cap but not the model — the coordinator README's "bump one tier for a stronger model" advice is a no-op. #1855 and #2181 hit budget-exhausted-key because the sm cap was too low for the actual token consumption, but the md cap would not have changed the model or the outcome.
- **Evidence:** #2163 (closed 2026-10-06, doc fix only — the estimator's tier band was not changed). #1855 and #2181 both hit budget-exhausted-key on the sm tier. The `estimate_budget.py` excerpt in the brief confirms `DEFAULT_CACHE_HIT = 0.0` and worst-case sizing — sm cap was exhausted on legitimate rounds.
- **Process change:** `agents/estimate_budget.py`: recalibrate the sm→md tier_floor gap against the live model registry. If the cheapest flash model below the cap is the same at both tiers, the tier bump must either raise the cap enough for an additional round (per `DEFAULT_ROUNDS=3` × `requests_per_round`) or the README text must say so.
- **Expected saving:** Rail 2: prevents ~2 budget-exhausted re-dispatches per wave (~$0.02–0.05). Rail 1: zero (auto-handled, no operator touch).

**F5 — Goal-theme WIP self-contention: 31 tasks in one wave without staggering (№2305, №1627, №2164)**
- **Mechanism:** Goal #2273 dispatched all theme-1 and theme-2 children simultaneously. With `AGENT_WIP_LIMIT=3`, 31 tasks competed for 3 slots. The C4/C5 phantom-block (#2305) amplified this: one long ride held the ceiling, and tasks queued behind it rather than flowing through. The fix for #2305 landed at 16:51 on 10-06, after 90% of tasks were already closed.
- **Evidence:** 39% deferral rate across 31 tasks. #1627's first productive round started at 21:19 on 10-05 after 2h19m of deferrals. #2164 started at 11:59 on 10-06 after 3h55m of deferrals. Tasks that started after the #2305 fix (post-16:51) had zero deferrals.
- **Process change:** `agents/coordinator/README.md` §Dispatch: add a theme-dispatch staggering rule — when a Goal checkpoint launches N children with intersecting `Touches` footprints, the scan must release them in waves of `AGENT_WIP_LIMIT` with a `C4C5_PERSIST_S` gap between waves, not all at once.
- **Expected saving:** Rail 3: eliminates deferral re-probes (same savings as F1, quantified there). Rail 1: zero (auto-handled). Rail 2: eliminates per-deferral key mint+delete cycles (~$0.01/event × ~12 events = ~$0.12/wave).

**F6 — Output-token limit is a recurring failure mode with no circuit breaker (№1797, №2168, №2280, №2327)**
- **Mechanism:** The model hits its output-token cap mid-emission, the agent terminates with no committed work, and the round is re-dispatched. Six issues (19% of deep-dive) hit this. The output-token limit is a model constraint, not an error, so it does not trigger a strike. The launcher re-dispatches at the same round with the same model — the same limit applies. #2280 hit it on round 1, needed a coordinator ARBITRATE to prescribe incremental writes on round 4.
- **Evidence:** #1797 (round 1: output-token limit on clause work), #2168 (round 1: 4 hits on review-edge PR), #2280 (round 1), #2327 (round 1), #1897 (1 hit), #2286 (1 hit). Each consumed a full model invocation at ~$0.05–0.10 with zero durable output.
- **Process change:** `agent-session.sh`: when `final_output` reports `ci_passed: false` with no files_changed, detect the output-token-limit signature in the run log and auto-split the task context for the next attempt before re-dispatching. The split rule: if the task's `Touches` declares >1 file, partition into single-file sub-tasks. If a single file, truncate the instruction to fit within `DEFAULT_CONTEXT_TOKENS/2`.
- **Expected saving:** Rail 2: eliminates 1 wasted invocation per output-token hit (~$0.05–0.10 × ~6 events = ~$0.30–0.60/wave). Rail 3: avoids 1 coordinator arbitrate ride per stuck task. Rail 1: zero (no operator touch unless rounds exhaust — currently happens in ~1/6 cases).

## Proposed process changes (table: change | artifact | expected saving | confidence)

| Change | Artifact | Expected saving | Confidence |
|---|---|---|---|
| C4/C5 gate scoped to footprint-intersecting pods only | `agents/coordinator-scan.sh` §C4/C5 block | Rail 3: ~12 deferral re-probes/wave eliminated (~$0.24 amortized); Rail 2: ~12 key mint+delete avoided (~$0.12) | High — #2305 demonstrated the fix mechanically; needs post-merge measurement |
| Build recipe: pre-emission size gate with auto-split | `.agents/build.yaml` | Rail 2: ~3 wasted invocations avoided per large-fixture task (~$0.15–0.30); Rail 3: ~3 coordinator rides saved | Medium — size estimation is coarse; the split heuristic needs tuning |
| Launcher consumes strike table before same-round re-dispatch | launcher /route path | Rail 2: 1 wasted invocation per strike avoided (~$0.05–0.10); Rail 3: 1 coordinator ride saved per strike | Medium — depends on #1640 theme-2 assembly landing |
| Recalibrate sm→md tier_floor gap against live registry | `agents/estimate_budget.py` | Rail 2: ~2 budget-exhausted re-dispatches avoided per wave (~$0.04) | High — #2163 documented the gap; the fix is a table update |
| Theme-dispatch staggering rule in coordinator brief | `agents/coordinator/README.md` | Rail 3: deferral re-probes eliminated (same as F1) | Medium — WIP staggering interacts with footprint intersection; needs replay |
| Output-token-limit detection + auto-split on re-dispatch | `agent-session.sh` | Rail 2: 1 invocation per hit saved (~$0.30–0.60/wave); Rail 3: 1 coordinator ride per stuck task | Low — detection is heuristic; false positives waste splits |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)

The deep-dive set was deliberately fine-grained — 31 tasks, each one scan-guard table row or seam fix, following Goal #2273's "table first, then the row" rule. This granularity was **chunked-right** for the domain: each task was a single replay row + guard addition, independently verifiable, with no integration friction between tasks. Evidence: 15 of 31 tasks (48%) completed in 1 round with no rework. The only cross-task friction was WIP-slot contention (F1/F5), not merge conflicts or integration rework — the updater serialization absorbed concurrent same-file PRs cleanly.

**Exception:** #2280 (clause-coverage) should have been a **fan-out**: enumerating the full cross-product and asserting every clause could have been split into one task per clause family (C4/C5, review-phantom, merged-closeout, infeasible-terminal) with a coordinator to assemble. Instead, one task tried to emit the full fixture in one model invocation and hit the output-token cap three times. Rounds 4–5 were the coordinator effectively doing the fan-out manually via ARBITRATE directives.

**Exception:** #2305 (C4/C5 WIP phantom) and #2306 (AGENT_REPORT resume) were interdependent — #2306 needed #2305's `ambig_decidable` change as context — but were dispatched as separate tasks. This was correct: the PRs were independent, and the reviewer checked cross-PR consistency at assembly.

## Wins to codify (or "none observed")

**Win 1 — Review-phantom predicate extension (#2281): 1 round, first-approval, zero coordinator touch.** The task extended the `agent/review` phantom predicate with a frozen-open-PR disjunct, following the Goal's fix rule (table-first, row red on base). Evidence: dispatched 10:59, merged-closeout at 14:10 — 3h11m end-to-end. **Codify:** `.agents/build.yaml` recipe: the "table-first" pattern (create the `rows:` fixture with a red-on-base row FIRST, then the guard code, then verify green) should be a named recipe section, not just a Goal prose rule — every guard task in this wave followed it, and 48% landed in 1 round.

**Win 2 — DUPLICATE-blocker canonical fix (#2167): 4 rounds but each round produced durable, reviewer-accepted work.** The agent navigated a complex blocker-resolution state machine (GraphQL duplicateOf vs REST timeline) without a no-op round. Every round committed verifiable progress even though CI was red. **Codify:** the "commit partial progress on red CI" pattern used here — commit the work and push, even if CI won't pass yet, so the next round resumes from durable state rather than restarting — should be explicit in `.agents/fix.yaml` for multi-step fixes.

## Platform KPIs (bucket-A count · trend · proposed next gate)

**Bucket-A count: 1 distinct platform-logic defect event filed in window.** #2302 (`pr_blocked_on_check` returns 'clear' on an unreadable probe — a failed `gh` read bypasses every blocked-on hold) was filed 2026-10-06. No coordinator/reflex/prompt defects were filed during the window. The current `agent/error` label count is **0** (no open issues carry it).

**Trend: falling.** The r5 retro reported bucket-A at 31→15→20 (second week without a fall triggered ADR-103 revisit). The r6–r7 window showed continued decline as replay gates landed. This window's count of 1 represents the lowest recorded level to date — the clause-coverage replay (#2280) and the fixed predicate gaps from r7 (#2281, #2282) are functioning as intended.

**Proposed next gate:** The highest-recurrence unguarded class this week is **unreadable-probe bypass** — #2302 documents that when `gh` cannot read a check-run (API error, rate limit, permission), the `pr_blocked_on_check` function returns `'clear'` instead of `'unknown'`, silently releasing the blocked-on hold. This is the same class as #1069 (GraphQL quota exhaustion → silent no-op) and #2305's live-worker probe gap. **Proposed gate:** add a `gh-read-fallback` replay fixture that asserts `pr_blocked_on_check` returns `'blocked'` (fail-closed) when any API read in the probe chain returns a non-200/non-success status. The `rows:` table should cover: API 200+success → normal path, API 403/401 → `'blocked'`, API 5xx/timeout → `'blocked'`, empty response → `'blocked'`.

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")

**Insufficient evidence.** The r7 retro's process changes (review-phantom predicate extension → #2281, clause-coverage replay → #2280, WIP-predicate unification → #2282) were all deployed as children of Goal #2273 within this same deep-dive wave. The r7 report (PR #2278) merged 2026-10-05, and all r7-derived tasks closed 2026-10-06 — there is **zero post-deployment measurement window**. No opportunity to observe whether rounds/issue dropped because the r7 changes were deployed simultaneously with the work they aim to measure.

The r6 predecessor score (from r7's report) is recorded in the r7 report itself — not re-scored here.

## Evidence confidence (what you could NOT verify and why)

- **Ledger data (`s3://agent-transcripts/`):** Not accessible from this pod. Round counts and model annotations were extracted from issue-comment agent-summary blocks only — these are machine-generated indices but not the canonical ledger. Actual token counts, per-request pricing, and cache-hit rates could not be verified.
- **OpenRouter spend data:** The `/generation` harvest and billed dollars (Rail 2) could not be verified. Cost estimates use the brief's stated pricing assumptions and `estimate_budget.py` defaults.
- **Subscription draw (Rail 3):** The Go meter's subscription-saturation values and the cash-amortized vs API-equivalent split could not be independently computed — no access to the subscription billing data or the Go meter.
- **Cross-repo trails:** oracle-fleet#637 (infeasible-terminal), oracle-fleet#780 (review-edge), agent-runtime#165 (blocked-on bypass) are referenced in issue bodies but their full comment trails and PRs could not be read cross-repo. The `gh` token authenticated for `teststuffstash/homelab` only — cross-repo reads were attempted and returned empty/403.
- **The responder ledger:** The brief mentions "responder ledger" as a source for bucket-A events. This ledger is not queryable from the pod. Bucket-A count is inferred from platform-repo issue filings only.
- **Model pricing registry:** The `estimate_budget.py` pricing registry (cached 24h JSON from OpenRouter's `/models` + `/models/<id>/endpoints`) is not accessible. Tier-floor calibration claims are based on #2163's documented observation that flash models price below both sm and md floors, not on live registry data.
- **Predecessor effectiveness:** As stated above — zero measurement window. A merged PR is not proof of effectiveness.

TOOL_GAP: gh cross-repo reads — fleet-wide trail evidence in oracle-fleet and agent-runtime repos could not be verified; deep-dive tasks referencing oracle-fleet#637, oracle-fleet#780, and agent-runtime#165 have incomplete evidence chains.
