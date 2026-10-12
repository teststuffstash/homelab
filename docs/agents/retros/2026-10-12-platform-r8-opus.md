# platform loop retro r8 — Claude Opus 5.5

## Coverage (window, bundle identity, completeness, late corrections)

**Window (taken from the bundle):** `since 2026-10-05T00:00:00Z` → `until 2026-10-12T00:00:00Z`, end exclusive. It starts exactly at r7's cutoff, so nothing was skipped. `collected_until 2026-10-12T18:00:07Z`, `covered_at 18:00:12Z`, `prepared_at 18:16:56Z`. That is about 13 h after the normal Monday 05:00Z start, but the cutoff itself is the normal one.

**Bundle identity:** `run_id r8`, `bundle_id 1b1d7e1c…b506`, `source_revision 381e1df2`, `storage_key platform/runs/20261012T000000Z`, `version 1`, `scope_source "live claims over committed mirror"`, 12 repos. I made the "is this still needed?" calls at about 2026-10-12 18:30Z.

**Whole-window population (every rate below uses these numbers, not the worst-K sample):**
- Activity: 8,529 events over 463 tasks; 25 agent-pain events; 230 failure events; **0 infra-failure events**; 132 superseded cancellations.
- Cost: worker cost **$12.819, measured on only 35 of 91** stat records.
- Ledger: **38 rows emitted**, 96 round entries.
  - Exits: clean 64, ci-failed 14, blocked-deliberate 8, no-op 5, budget-403 3, auth-storm 1, input-unreadable 1.
  - First touch by model: deepseek-v4.1-flash:exacto on 20 tasks (9 non-clean), haiku on 9 (3), sonnet on 8 (3).

**Completeness:**
- The serialized ledger holds only **21 of the 38 rows** because of the `max_serialized_bytes 60000` limit. Per-model numbers drawn from rows are labelled as sample-level. Population counters are used wherever they exist.
- Ranks 1–8 resolve to **five distinct work items**: Goal #2273, #2168/PR#2315(+#2325), #2100, #2305/PR#2319, and #2281/PR#2318. Issue↔PR pairs still take two rank slots each; r7 already reported this residual and it is not refiled here.

**Ledger fields that can't be trusted (stated once):**
- `reviewer_rounds` = 0 everywhere, so every review round below was counted from the PR trails.
- `wall_time_s` isn't split into active and idle time. The biggest outlier, #2167 at 356,515 s, is PR #2174 open from 10-02 16:53 to 10-06 19:57. That is idle time of r7's F1 class (BEHIND/duplicate-blocker), not slow work.
- `retry_storms` is harness-level only.
- `total_cost_usd 0.00` on haiku/sonnet rows (#2305, #2281, #2164, #2282, #2328, oracle-fleet#829) means untracked, not free.

**Late arrivals:** 943 late events. All 20 sampled events belong to **July 2026** periods (homelab#1 ×17, sleep-tracking#67 ×3) and were observed 10-10/10-11. They are corrections to those July periods and change none of this window's totals. The other 923 are not in the bundle, so I couldn't classify them.

## Summary (≤5 lines)
1. One day (10-06) of Goal #2273 children produced **17 of the window's 44 CHANGES_REQUESTED verdicts, all citing pin vacuity and all on `goal/**` bases**. Master-based PRs got none, because the CI vacuity gate is binding on master but only a `::warning::` on stacked bases.
2. Ten hands-on fixes by the seat (the operator's unattended session) kept that goal moving. Three mechanisms caused most of them: cap exhaustion reported as a "deliberate stop", subscription rides charged their full cap against the goal `Budget:`, and an arbitrate round that was deferred for capacity and then never re-fired.
3. The **predecessor fixes worked**: r7 F1 (post-approval BEHIND idle) dropped from 49–54 h to a ≤0.9 h maximum across 160 post-deploy merges. #2147 still holds: 3 rides on 25 force-pushes of #2100.
4. Bucket-A is **14** (13 → 13 → 14), the third week without a fall. Most of it comes from defects the goal's own census uncovered. Proposed next gate: widen the clause-coverage replay that landed issue-label-only to the PR-state axis it dropped (goal/assembly states).

## Findings (ranked, ≤6)

### F1 — The pin-vacuity gate only warns on `goal/**` bases, so the reviewer ends up enforcing it one round at a time
**Evidence (in window, from trails):**
- Of 44 bot CHANGES_REQUESTED verdicts on homelab PRs, 22 were on `goal/2273-*` bases. **17 of those 22 (77%) block on a vacuous pin or unreached pin wiring**, spread over 11 PRs: #2315 ×2, #2318 ×2, #2319 ×3, #2321 ×2, #2332 ×2, and one each on #2292, #2322, #2325, #2329, #2331, #2334. All of them fall between 07:10Z and 16:08Z on 10-06.
- **Master-based PRs: 0 of 22 vacuity verdicts.**
- I checked the CI annotations on four of these PRs at their first commit (#2321, #2325, #2331, #2334). Each carries `::warning::ADR-103 pin-vacuity: cannot prove vacuity against stacked base 'goal/2273-…' — Unproven, not vacuous`. The reviewer then confirmed vacuity on every one ("`bridge.sh` hardcodes its own copy of the jq defs… rows would stay green if the fix were reverted", [#2325](https://github.com/teststuffstash/homelab/pull/2325#pullrequestreview-5430002522)).
- Two PRs ran out the 5/5 round cap with vacuity among the remaining blockers:
  - **#2315** was closed unmerged, and the work was redone as #2325, which took 4 more rounds. #2168 ran from 05:50 to 15:21Z.
  - **#2318** was finished by a seat fix at 13:40Z.
- Goal #2273's own fix rule requires "the failing case red on the base tree **per the pin-vacuity gate**". The gate it points to is exactly the one that is advisory on the goal's base.

**Mechanism (falsifiable):** `ci.yaml`'s ratchet step (lines 417–424) downgrades a pass-on-base to a warning whenever `GITHUB_BASE_REF != master`. That is homelab#1225 face 2: the fix might already be in the stacked base. Workers ship whatever CI leaves green.
- Prediction: if the stacked-base branch reverts only the PR's *own* changed clause files instead of trusting the base tree, vacuity verdicts on `goal/**` drop to the master rate (≈0). The face-2 concern also disappears, because a fix that predates the PR isn't among the files that get reverted.
- Side note (sample-level, likely selection bias): 8 of the 11 PRs were haiku-authored.

**Change:** in the ADR-103 pin-vacuity step of `.github/workflows/ci.yaml`, when the base is not master:
1. In a copy of the PR checkout, run `git checkout <merge-base> -- <this PR's changed clause files>`.
2. Run the changed fixtures against that copy.
3. Use the existing `::error` + `exit 1` instead of `::warning::`.

This is the same procedure the window's cleanest PR used by hand (see Wins). It is operator-lane (`.github/**`).

**Expected saving:**
- **Rail 3 / 2:** about 17 fix rounds plus 17 review rides a week at this goal cadence. Most were haiku (subscription: cash-amortized ≈ $0 under headroom; API-equivalent from the Go meter, e.g. #2315 R5 alone was 229k in + 10.2M cached / 38k out). The deepseek rounds cost $0.03–0.13 each.
- **Rail 1:** 2 round-cap parks a week. The seat absorbed both this time; when one reaches the human it is a full E, **€20–30 each (€40–60/wk)**.
- **Wall time:** 2.9 h (#2318) and 5.2 h (#2168) on the critical path to the theme assemblies.

**Confidence:** high.

### F2 — The goal-budget pre-flight charges subscription rides their full cap, so it refuses on spend that never happened
**Evidence:**
- [AGENT_BUDGET_REFUSED 17:17Z](https://github.com/teststuffstash/homelab/issues/2273#issuecomment-6021570621): Σ $30.32 > $30. **$15.00 of that Σ is nine haiku/subscription rides charged at full cap** ("ridden, no ledger entry — FU-131 gap, conservative"), including $4 each for #2168 and #2305. Actual settled paid spend was about $15.3.
- The refusal itself says "a human decision either way". The [seat raised `Budget: 30 → 36`](https://github.com/teststuffstash/homelab/issues/2273#issuecomment-6021861552) at 17:34Z.
- The [seat then ran ARBITRATE round 6 by hand](https://github.com/teststuffstash/homelab/pull/2329#issuecomment-6022864459) at 18:31Z, because the refused dispatch never re-fired. That was #2280, theme 1's last member and the gate on assembly #2339: **74 min** of stall.
- The same cap-charge pattern appears in earlier refusals (prior-period context): oracle-fleet#281 09-02 (5 cap-charged children), #579 09-14 (1), and #436 09-16 (2).

**Mechanism:** the pre-flight can't tell "subscription ride, nothing billed to OpenRouter" from "paid ride whose `/generation` harvest missed". It charges both at cap. Each subscription child therefore inflates Σ by its whole tier, and goals that lean on the haiku rail hit a refusal at about half their real spend.

**Change:** in the launcher's goal-budget pre-flight (FU-090 leg (c), the `AGENT_BUDGET_REFUSED` emitter), charge **$0 against `Budget:`** for a ridden child whose `agent-stats` line records `subscription`. That line exists, e.g. #2315 "model `haiku` · exit `clean` · subscription". Keep the conservative cap-charge only for paid-rail rides that have no ledger entry. FU-131 is related work; its remaining T+1 sweep doesn't cover this.

**Expected saving:**
- **Rail 1:** removes a refusal class whose text demands a human. **€20–30 per avoided out-of-sitting summons**, at about one per budgeted goal-week (4 such refusals since 09-02).
- 74 min of goal stall.
- No rail-2 saving, because the refusal never stopped real spend.

**Confidence:** high.

### F3 — Hitting a cap is reported as a "deliberate stop", so there's no strike swap and the issue becomes a phantom the seat has to requeue
**Evidence:**
- **All 8 of the window's `worker-stop-report` entries** (the population counter) are deepseek-v4.1-flash:exacto round-1 rides on 10-06, 05:21–10:30Z.
- In the trails, **6 of the 8 cite a cap**:
  - output-token limit ("Response reached the model's output-token limit… call `final_output` NOW"): [#1897](https://github.com/teststuffstash/homelab/issues/1897#issuecomment-6010081357), [#2286](https://github.com/teststuffstash/homelab/issues/2286#issuecomment-6012722710), #1797, and #2168 07:18Z
  - max-turns: [#1923](https://github.com/teststuffstash/homelab/issues/1923#issuecomment-6011945201)
  - key credit ("add more credits"): [#2308](https://github.com/teststuffstash/homelab/issues/2308#issuecomment-6014356382)
  - The seat ruled #2168's 09:32Z stop a cap hit as well ("hit the turn/output cap twice at sm").
- What followed was **5 seat touches in one morning**:
  - requeues of phantom `agent/in-progress` on [#2168 06:36Z](https://github.com/teststuffstash/homelab/issues/2168#issuecomment-6010812574), [#1797 06:40Z](https://github.com/teststuffstash/homelab/issues/1797#issuecomment-6010863892) and [#1714 09:35Z](https://github.com/teststuffstash/homelab/issues/1714#issuecomment-6013473057)
  - tier re-grades on [#2168 sm→md](https://github.com/teststuffstash/homelab/issues/2168#issuecomment-6013475143) and #2305 sm→lg
- Phantom wait before the requeues: 32 min, 79 min and 54 min.

**Mechanism:** the jail-side classifier (`>>>REPLAY:strike-quota-classifier>>>` in `agents/agent-session.sh`, lines ~3104–3135) has no signature for `reached the model's output-token limit` or `add more credits`. Its existing patterns are `response may have been truncated` and `insufficient (credit|fund)|out of credit`. The harness-forced `final_output` text is then filed as a deliberate `AGENT_REPORT`, which bypasses ADR-127's strike→swap and the `turn-cap` auto-retry. This class was misfiled the same way by 08:41Z, but the seat requeue followed only at 09:35Z.

**Already fixed in substance:** #2305 (per-issue liveness) and #2306 (resume after a deliberate stop) reached master at 10-06 19:23Z and close the phantom half. The **classification half is open** and has no existing issue (I searched "output-token limit", "add more credits" and "final_output").

**Change:** add two patterns, ahead of the deliberate-stop path, to that classifier block and to its authoritative copy in agent-runtime's `agent-finalize`:
- `reached the model.s output-token limit` → `turn-cap`, which is already serving-shaped, so it gets one automatic retry or swap
- `add more credits` → `budget-403-key`

**Expected saving:**
- **Rail 1:** 3–5 in-sitting touches a week, **€3–8 each (≈€15–40/wk)**, or a full E when one lands outside a sitting.
- About 2.75 h a week of child stall.
- **Rail 2:** the second deepseek round that re-ran into the same cap (#2168 ran 3 times).

**Confidence:** high on classification (6 of 8 verified), medium on frequency (one goal-day).

### F4 — The estimator's fixed 20k context undersizes anything that touches the 514 KB scan
**Evidence:**
- `agents/coordinator-scan.sh` is 514,591 bytes, about 128k tokens at the estimator's `CHARS_PER_TOKEN = 4`. `DEFAULT_CONTEXT_TOKENS = 20_000`.
- In this window, scan-footprint children hit caps:
  - #2181 R1 `budget-403` (sm), then $1.17 total
  - #2280 R6 `budget-403` (md)
  - #2308 R1 key credit exhausted (sm)
  - 4 output-token stops (F3)
- Two seat re-grades the same day: #2168 sm→md, and #2305 sm→lg (r9–r10).
- Sample-level spend over the sm $1 per-session cap: #1896 $2.09 over 2 rounds, #1627 $1.10 over 5.

**Mechanism:** the estimate is driven only by issue text: `requests_per_round(issue_tokens) × context_tokens`. The context term never sees the size of the footprint the worker has to read, so every guard in a 6,746-line file is priced like a small script.

**Change:** in `agents/estimate_budget.py`, derive the context term from the issue's `Touches:` footprint as `max(DEFAULT_CONTEXT_TOKENS, Σ footprint bytes / CHARS_PER_TOKEN, capped)` before `pick_tier`. Leave the `TIERS` band ceilings alone.

**Expected saving:**
- **Rail 2:** about $1–4/wk of budget-403 rounds that commit nothing.
- **Rail 1:** 2 in-sitting re-grades/wk (€6–16).
- Predecessor r3 F5 (headroom 2.0) didn't cover this case.

**Confidence:** medium. Cost is measured on only 35 of 91 records.

### F5 — If an arbitrate-directed fix round is deferred for capacity, the arbitrate debounce holds and the directive goes to the seat
**Evidence:**
- #2319/#2305: the ARBITRATE directive came at 15:27Z and the `state-fp:arbitrate` marker at 15:28Z.
- [Round deferred (capacity)](https://github.com/teststuffstash/homelab/issues/2305#issuecomment-6019664234) at 15:30Z: WIP 2/2. The comment says "the next pass re-probes and dispatches it".
- Nothing ran until the [seat applied the edit directly at 16:38Z](https://github.com/teststuffstash/homelab/pull/2319#issuecomment-6020914338): **68 min**.

**Mechanism:** in `coordinator-scan.sh`'s `>>>REPLAY:arbitrate-gate>>>`, no stats newer than the marker means DEBOUNCED plus a `who=operator` board row. FU-199 rule 2 ("no stats newer than the marker ⇒ the marker is stale, re-arm") was applied to the ci-red gate only. The deferral comment's promise is therefore false on the arbitrate path.

**Change:** in the arbitrate-gate block, treat a `Round deferred (capacity)` comment newer than the newest state-fp marker as re-arming, the same way FU-199 handles ci-red.

**Expected saving:** one in-sitting touch, **€3–8** (a full E if it happens outside a sitting), plus about 1 h of PR stall per occurrence.

**Confidence:** low on frequency (n = 1 this window), high on mechanism (code read).

## Proposed process changes (table: change | artifact | expected saving | confidence)

| change | artifact | expected saving | confidence |
|---|---|---|---|
| On non-master bases, revert the PR's own changed clause files to merge-base, re-run the changed fixtures, and `::error` (not `::warning::`) if none go red | `.github/workflows/ci.yaml` ADR-103 ratchet, pin-vacuity step (L417–424; operator-lane) | Rail 1: €40–60/wk (2 round-cap parks, if they reach the human); rails 2–3: ~17 fix + 17 review rides/wk; 3–5 h critical-path wall time | high |
| Charge $0 against `Budget:` for children whose stats say `subscription`; keep the cap-charge for paid rides with no ledger entry | launcher goal-budget pre-flight (FU-090 leg (c), `AGENT_BUDGET_REFUSED`) | Rail 1: €20–30 per avoided refusal (~1/budgeted goal-week); 74 min of goal stall; no rail-2 saving | high |
| Classify `reached the model's output-token limit` → `turn-cap` and `add more credits` → `budget-403-key` before the deliberate-stop path | `agents/agent-session.sh` `strike-quota-classifier` block + agent-runtime `agent-finalize` signatures | Rail 1: €15–40/wk (3–5 in-sitting seat touches); ~2.75 h/wk of child stall; rail 2: repeat cap rounds | high (class) / medium (rate) |
| Context term = max(20k, `Touches:` footprint bytes ÷ 4, capped) | `agents/estimate_budget.py` (`DEFAULT_CONTEXT_TOKENS` → footprint-derived) | Rail 2: ~$1–4/wk; Rail 1: €6–16/wk (2 re-grades) | medium |
| A `Round deferred (capacity)` comment newer than the marker re-arms the arbitrate gate | `agents/coordinator-scan.sh` `arbitrate-gate` block (FU-199 rule 2, extended) | Rail 1: €3–8 per occurrence (n = 1/wk observed) | low |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)

- **Goal #2273 (rank 1): chunked right.**
  - 32 descendants went from filing (10-05 18:35Z) to both themes assembled (10-06 19:34Z) in about 25 h. 17 of 30 child PRs were approved on first review.
  - The rounds were burned **inside chunks** (F1's 17 vacuity verdicts), not across them.
  - Real cross-chunk friction came to about 3 rounds:
    - #2329 round 6 had to reconcile the `pods` axis that #2305 added to `c4c5-selector`.
    - The #2318 review exposed two "ci green" definitions and spawned #2328/PR#2334 (2 rounds).
    - Assembly #2333 got one bot BLOCKING finding (a footprint escape).
  - One larger-model task would have lost the per-guard tables the goal exists to produce.
- **#2168 → PR#2315 + PR#2325 (ranks 2 and 8): should have been one stronger-model task from the start.**
  - 3 deepseek round-1 stops at the output cap (F3). Then 5 haiku rounds on #2315 never converged: the fix keyed on `bodyLastEditedAt`, a field the query never fetched, and the PR was closed unmerged at 5/5.
  - After the seat's re-scope named the real field (`lastEditedAt`), PR#2325 landed in 4 rounds.
  - About 9 of 12 rounds were in-chunk misunderstanding of the API surface; none were cross-chunk.
- **#2100, the mermaid v12 major (rank 3): chunked right.**
  - 1 lens round. The 45.3 h between approval (10-09 12:35Z) and human merge (10-11 09:51Z) is the `major/awaiting-human` gate working as designed.
  - 25 force-pushes drew only 3 unarmed-major rides.
- **#2305 → PR#2319 (ranks 4 and 6): chunked right, but under-modelled.**
  - 9 haiku rounds (2 ci-failed, 1 no-op) and 3 CR verdicts, all about pin wiring (an unreached `PROBE_FAILED` row, then an expectation that contradicted its own contract), plus 2 ARBITRATE directives.
  - The seat re-graded it to lg only at round 10.
  - 1 cross-chunk round, absorbed downstream in #2329.
- **#2281 → PR#2318 (ranks 5 and 7): chunked right.**
  - 5 haiku rounds (2 ci-red) and 4 CR verdicts: a vacuous bridge-injected variable, a `set -u` crash, a missing falsifier, and an edited world row. Then the seat finished it after 5/5.
  - The one cross-chunk item (two ci-green definitions) was correctly split out as #2328.

## Wins to codify (or "none observed")

**PR [#2309](https://github.com/teststuffstash/homelab/pull/2309)** (#2181, deepseek) was approved on first review 5 min after opening, at [07:10Z](https://github.com/teststuffstash/homelab/pull/2309#pullrequestreview-5424965011). Its body does the two things whose absence cost #2315 and #2325 their rounds:
1. **A self-run vacuity check:** "Pin-vacuity was checked by reverting only the two scripts to the base tree and re-running: the two major-handoff rows and the review-pick fixture red exactly as above."
2. **Live-verified field claims:** "`gh pr view 2301 --json commits --jq '.commits[0]|keys'` → [...]" before relying on a `gh` field.

PR#2317 (#2282) did the same for (1) ("Sidecar-held row red on base") and was also approved on first review.

**Codify:** add one line to `.agents/fix.yaml`'s PR-body requirements block: *revert only your changed source files to base, re-run your new fixture, paste the red output; for every `gh --json` field you newly read, paste the live `keys` output.* (1) is the manual version of F1's CI change and covers repos and paths outside clause-replay.

## Platform KPIs (bucket-A count · trend · proposed next gate)

**Bucket-A: 14.** I used r7's rule: distinct platform-logic defect issues filed against homelab in the window, in the coordinator, review-reflex, prompt-brief, scan and launcher/worker-harness classes.

| class | count | issues |
|---|---|---|
| scan | 12 | #2281, #2282 (scan∧launcher), #2302, #2305, #2306, #2308, #2326, #2327, #2328, #2341, #2370, #2477 |
| prompt-brief | 1 | #2286 |
| coordinator | 1 | #2307 |

Excluded under the same rule:
- CI-lint / platform-gate: #2262, #2364, #2371, #2376, #2412
- carriers / dependency work: #2255, #2259, #2356
- other: #2242 (model scout), #2489 (alert)

**Trend: 13 → 13 → 14, a third week without a fall.**
- Two qualifiers: #2281 and #2282 are r7 findings refiled as goal members on 10-05. Six (#2305, #2306, #2326, #2327, #2328, #2308) surfaced through the census goal's own children and reviews on 10-06.
- After the assembly (10-06 19:34Z → 10-12), the count is **3 in 5.2 days** (#2341, #2370, #2477), about 4/week.
- So the headline meets ADR-103's non-fall condition, but it is inflated by discovery.
- **Recommendation:** decide on the AgentStack-CR revisit once Goal #2273's own production leg has been scored (two weeks after assembly, about 10-20). If that window is still ≥13, the trigger stands.

**Proposed next gate (mandatory):** widen the clause-coverage replay (`agents/replay/fixtures/clause-coverage/`, PR #2329) beyond the issue-label axis to the **PR-state axis it dropped**, starting with goal-lifecycle states: goal open × assembly PR {absent, open-awaiting-human, merged} × child set. It should assert exactly one owning clause or hold for each state.
- This is the highest-recurrence class still unguarded this week:
  - #2477 (checkpoint trigger (b) re-fires while the assembly PR awaits a human, ~25 rides/h `DispatchClauseStorm`, [oracle-fleet#828](https://github.com/teststuffstash/oracle-fleet/issues/828#issuecomment-6100924648))
  - #2370 (the closeout leg admits a blocked child)
  - #2306 (goal-child resume)
  - plus the #2280 closeout that hadn't fired after about 30 min ([seat close](https://github.com/teststuffstash/homelab/issues/2280#issuecomment-6023509488))
- None of these are expressible in the issue-label-only enumeration that landed.

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")

- **r7 F1 (homelab#2281 → PR#2318, together with #2203's merge-queue fix): deployed and effective.**
  - Reached master via #2339 at 10-06T19:23:53Z.
  - Opportunities: **160** approved homelab PRs merged from 10-06T19:30Z to 10-12.
  - The largest approval→merge gap for a PR that wasn't human-gated is **0.9 h** (median 0.1 h), against r7's 49.3 h and 54.0 h. Every gap above 2 h is a `major/awaiting-human` PR or a codeowner PR (#2100, #2488, #2392).
  - The two fixes landed in the same assembly, so the credit is shared.
- **r7 next gate (#2280 → PR#2329): deployed narrowed, partially effective.**
  - It landed as "every admissible **issue label** state". PR-state × check-conclusion were dropped.
  - After deploy, 0 new "invisible to every clause" defects in 5.2 days, but 2 new scan defects on the dropped axes (#2370, #2477). That leads to this report's next gate.
- **r7 F4 (red-first receipt): not deployed as rubric text** (`.agents/review.md` has no red-first clause). Its substance was adopted as Goal #2273's child rule, but the only enforcement is the stacked-base warning. **Ineffective as deployed:** 17 vacuity verdicts (F1).
- **r7 F2 (one fixture-only round after the round cap): not deployed** (absent from the coordinator README). There was an opportunity: #2318 reached 5/5 with only fixture/world residuals and the seat fixed it at 13:40Z.
- **r7 F5 (`egress-denied` class): not deployed.** agent-runtime#164 is open and `agent-session.sh` has 0 matches. Insufficient evidence: `infra_failure_events` is 0 again.
- **r7 F3 (run ratchets before push): deployed in substance** via PR#2468, merged 10-10T19:02Z (`githooks/pre-push` runs the diff-ci push gates). Insufficient evidence: about 1.2 days after deploy, and I couldn't confirm whether worker pods run the hook.
- **r6/#2147 (unarmed-major fingerprint keyed on content): still effective.** On #2100 this window: 25 force-pushes, 3 unarmed-major rides (r7 pre-fix rate was about 3.1 rides/day).

TOOL_GAP: retro bundle `previous_findings` — the array is empty although `previous_findings_total` is 12, so I couldn't reuse prior mechanism/surface strings verbatim and took predecessor scoring from the r7 opus report file instead.

```retro-findings-json
{"schema_version":1,"findings":[{"mechanism":"pin-vacuity-gate-advisory-on-stacked-base","surface":".github/workflows/ci.yaml ADR-103 ratchet pin-vacuity step","summary":"On goal/** bases a pass-on-base fixture only emits ::warning:: (homelab#1225 face 2), so 17 of 22 goal-base CHANGES_REQUESTED verdicts this window blocked on vacuous pins (0 on master) and two PRs hit the 5/5 cap; on non-master bases, revert the PR's own changed clause files to merge-base, re-run the changed fixtures and ::error if none reds","evidence":["https://github.com/teststuffstash/homelab/pull/2325#pullrequestreview-5430002522","https://github.com/teststuffstash/homelab/pull/2322#pullrequestreview-5428578087","https://github.com/teststuffstash/homelab/pull/2331#pullrequestreview-5430832987","https://github.com/teststuffstash/homelab/pull/2318#pullrequestreview-5427516714","https://github.com/teststuffstash/homelab/pull/2321#pullrequestreview-5427980150","https://github.com/teststuffstash/homelab/pull/2315"],"related_work":["https://github.com/teststuffstash/homelab/issues/1107","https://github.com/teststuffstash/homelab/issues/1225","https://github.com/teststuffstash/homelab/issues/931","https://github.com/teststuffstash/homelab/issues/2273"]},{"mechanism":"goal-budget-preflight-charges-subscription-rides-full-cap","surface":"launcher goal-budget pre-flight (FU-090 leg (c), AGENT_BUDGET_REFUSED)","summary":"Nine subscription-rail children were charged their full cap ($15 of a $30.32 sigma), causing a refusal that demands a human, a seat Budget edit and a hand-executed ARBITRATE round (74 min stall on theme 1's last member); charge $0 against Budget: for rides whose stats record subscription","evidence":["https://github.com/teststuffstash/homelab/issues/2273#issuecomment-6021570621","https://github.com/teststuffstash/homelab/issues/2273#issuecomment-6021861552","https://github.com/teststuffstash/homelab/pull/2329#issuecomment-6022864459"],"related_work":["https://github.com/teststuffstash/oracle-fleet/issues/281","https://github.com/teststuffstash/oracle-fleet/issues/436"]},{"mechanism":"cap-exhaustion-reported-as-deliberate-stop","surface":"agents/agent-session.sh strike-quota-classifier + agent-runtime agent-finalize","summary":"All 8 worker-stop-report rounds were deepseek-v4.1-flash round-1 rides and at least 6 hit an output-token, turn or credit cap, but were filed as deliberate AGENT_REPORT stops, bypassing strike swap and turn-cap retry and causing 3 seat requeues and 2 re-grades; add output-token-limit to turn-cap and add-more-credits to budget-403-key signatures ahead of the deliberate-stop path","evidence":["https://github.com/teststuffstash/homelab/issues/1897#issuecomment-6010081357","https://github.com/teststuffstash/homelab/issues/2286#issuecomment-6012722710","https://github.com/teststuffstash/homelab/issues/1923#issuecomment-6011945201","https://github.com/teststuffstash/homelab/issues/2308#issuecomment-6014356382","https://github.com/teststuffstash/homelab/issues/1797#issuecomment-6010863892","https://github.com/teststuffstash/homelab/issues/2168#issuecomment-6013475143"],"related_work":["https://github.com/teststuffstash/homelab/issues/2305","https://github.com/teststuffstash/homelab/issues/2306","https://github.com/teststuffstash/homelab/issues/1665"]},{"mechanism":"estimator-fixed-context-undersizes-large-footprint","surface":"agents/estimate_budget.py DEFAULT_CONTEXT_TOKENS","summary":"The fixed 20k context term prices children touching the 514 KB coordinator-scan.sh (~128k tokens) like small scripts: 3 budget-403/credit cap hits and 2 seat tier re-grades this window; derive the context term from the issue's Touches: footprint size","evidence":["https://github.com/teststuffstash/homelab/issues/2181","https://github.com/teststuffstash/homelab/issues/2280","https://github.com/teststuffstash/homelab/issues/2308#issuecomment-6014356382","https://github.com/teststuffstash/homelab/issues/2168#issuecomment-6013475143"],"related_work":[]},{"mechanism":"arbitrate-debounce-holds-after-capacity-deferred-round","surface":"agents/coordinator-scan.sh arbitrate-gate","summary":"A capacity-deferred, arbitrate-directed fix round left the state-fp:arbitrate marker armed with no stats, so the gate stayed DEBOUNCED for 68 min until the seat applied the edit by hand; re-arm on a Round deferred (capacity) comment newer than the marker, as FU-199 does for ci-red","evidence":["https://github.com/teststuffstash/homelab/issues/2305#issuecomment-6019664234","https://github.com/teststuffstash/homelab/pull/2319#issuecomment-6020914338"],"related_work":[]}]}
```

## Evidence confidence (what you could NOT verify and why)

- **Ledger truncation:** only 21 of 38 rows are serialized. Per-model and per-tier figures from rows (haiku 41 rounds, 7 ci-failed, 5 no-op; the sm overruns) are sample-level. Population counters were used for every rate claim.
- **Worker transcripts** (`s3://agent-transcripts/`) weren't read. The F3 cap attribution rests on the last 15 log lines in each `AGENT_REPORT` comment. Two of the 8 stops (#1714, and #2168 09:32Z) carry no cap signature in that tail; the seat's ruling is the only evidence for #2168.
- **"Seat" cost rail:** the seat signs as "operator's unattended session". The rail-1 numbers above are the exposure if the human takes the item. When the seat absorbs it, the cost is rail 3, which I can't price because the Go meter and Grafana dashboards are outside this pod (homelab#587).
- **Responder ledger:** not reachable here. Bucket-A is counted from homelab issues only, under r7's rule, and the class assignments are my reading of titles and bodies.
- **F1 CI annotations:** checked on 4 of the 11 PRs. #2322's first commit showed no vacuity annotation, possibly because no clause changed in that commit.
- **F2's prior refusals** (oracle-fleet#281/#436/#579) are prior-period context and don't count toward this window.
- **F5 is n = 1.** I didn't confirm whether any other deferral marker text exists beyond the two search hits.
- **Pre-push hook in pods (r7 F3):** I couldn't verify that worker pods run `githooks/pre-push`.
- **Late arrivals:** 923 of the 943 aren't in the bundle (`max_late_events 20`). Their periods are unknown beyond the July sample.
- **Cost coverage:** paid cost is measured on 35 of 91 stat records, so rail-2 figures are lower bounds.
