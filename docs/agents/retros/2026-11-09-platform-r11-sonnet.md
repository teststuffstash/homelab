# platform loop retro r11 — Sonnet 5.5 (claude-sonnet-5-5)

## Coverage (window, bundle identity, completeness, late corrections)
- Window is 2026-11-02T00:00Z to 2026-11-09T00:00Z (exclusive). The bundle was collected until 2026-11-09T04:30:08Z, and the run was prepared 2026-11-09T05:00:09Z (run_id r11).
- Bundle id is `38bbe4bf636c36b826cb015212b7b5d81952a1ebc870a18ab5ea434ff9cd43ed`. Source revision is `79eaf00c`.
- Population is 215 tasks and 2784 events. 23 tasks were selected, and the ranked set is capped at 8 events each. The bundle's `limitations` say it covers GitHub activity only. Worker sessions, token cost and deployments are not collected.
- The ledger has 10 rows and 16 round entries. 8 rows are `agent/done` and 2 are `agent/blocked`. 2 rows are snapshots with `wall_time_s=0`.
- `worker_cost_measured_records=0`, so no billed-dollar figure exists for the week.
- Late arrivals: 409 observed after their period. The bundle shows 20 of them, and the 409 total is taken from its population statistics. The 20 shown are:
  - 1 sleep-iac CI event from 2026-08-30.
  - 13 events on homelab#1643 from 2026-09-13 to 2026-09-16, a pre-pull alert issue filed and closed in September.
  - 6 events on homelab#1906 on 2026-09-22.
  - None of the 20 changes the window totals. They belong to their original periods.
- Ledger blind spots (FU-058): `reviewer_rounds`, `wall_time_s`, `retry_storms` and `total_cost_usd=0.00` are unreliable. I counted rounds from trails and did not use those fields.
- Rows for oracle-fleet#946 (2026-11-02T20:30Z) and #999 (2026-11-02T01:00Z) sit at the window edge. I did not drill into them.

## Summary (≤5 lines)
1. The largest rank-1 round burn, oracle-fleet#1021, was a platform fault rather than a model fault. Pods got github release-asset 504s on the pr-open gate. Two rounds produced finished work and stopped, a third was refused, and the issue sat open about 9 hours until a human-side fix (homelab#3214). Five rounds were spent in total.
2. oracle-fleet#965 and sleep-tracking#218 (garage v2.5.0, a Renovate bump outside the ADR-158 window) show a review loop on an unfixable PR. #965 drew 4+ CHANGES_REQUESTED reviews and #218 drew 7. It cost ~50 h of standing stall and ended in `agent/error`.
3. Security-bump PRs openrouter-operator#110 and #111 are armed and approved but red. The `deps-pin-guard` refuses graph changes, so they needed a human-owned lock route (#113). They were about 49 h stalled and are still open.
4. Single-chunk build rides that landed first-round clean: #1022 (xs, 679 s), #974, #924 and #999. Calibration at the xs and md tiers looks fine.
5. Bucket-A (platform-logic) count this week is 5 distinct events, from the trail evidence only. The proposed next gate is a same-finding review-loop breaker.

## Findings (ranked, ≤6)

**F1 — A platform gate failure was ridden into round-burn and phantom re-queue.**
- Evidence:
  - oracle-fleet#1021 ran 5 ledger rounds. Rounds 1 and 2 (2026-11-08T09:39Z and 10:15Z) ended in `AGENT_REPORT: deliberate stop`, with the branch pushed and the change finished.
  - The cause was that the pr-open gate cannot fetch the snippets wheel (github release-asset 504 from pods).
  - The coordinator ruled "round 3 NOT dispatched" at 10:18Z and filed homelab#3214. That issue was closed 2026-11-08T16:16Z.
  - The scan then cleared a "phantom" `agent/in-progress` and re-queued at 10:34Z. Rounds 3 to 5 then ran (no-op, clean, clean) and the PR merged 19:12Z. Elapsed about 10 h.
  - homelab#3211 round 1 parked for a human on 2026-11-08T05:16Z, and the worker reported the same stop-report class.
  - The ledger shows 4 `worker-stop-report` errors on 3 tasks.
- Mechanism: when a coordinator ruling blocks dispatch on an environmental cause, the scan's phantom-clear re-queues the issue anyway. A ruling that says "do not ride until X is fixed" is not a native `blockedBy` edge, so it does not hold the scan. The result is a no-op round, plus a 6 h wait for the platform fix.
- Process change: in the README state machine, make a coordinator "round NOT dispatched, blocked on cross-repo issue N" ruling write a native `blockedBy` edge to N. The scan clause that clears phantom `agent/in-progress` must treat an open blocker as a HOLD. The README says dependencies are native `blockedBy` edges and closed is the satisfaction proxy, so this reuses an existing mechanism.
- Expected saving: avoids about 1 no-op round per environmental park and about 1 operator touch per park. In-sitting, that is €3–8. Out-of-sitting, it is €20–30. Rail 2 (paid API) is unmeasured, since cost is untracked.

**F2 — The reviewer repeats an identical, unfixable CHANGES_REQUESTED on every Renovate rebase.**
- Evidence:
  - sleep-tracking#218: 7 CHANGES_REQUESTED reviews from 2026-10-31T16:52Z to 2026-11-06T13:45Z, all with the same finding (garage v2.5.0 is two minors ahead of prod v2.3.0).
  - oracle-fleet#965: the same finding at d89f56d, 894fce1, 194b3bb and a08062d. A coordinator ARBITRATE (2026-10-31T21:22Z) escalated to a human, and `agent/error` was applied 2026-11-03T00:36Z.
  - Standing stall is 209,664 s on #218 and 7,886 s on #965 in the window.
  - Both PRs are still open.
- Mechanism: nothing latches a PR once the reviewer's verdict depends only on a fact that no fix round can change (a version window on prod). Each rebase changes the head SHA, so the `state-fp:` moves and the loop re-reviews.
- Process change: add a reviewer rubric clause. When the prior N≥2 verdicts at distinct heads carry the same finding id and the diff delta is rebase-only, post a single `STANDING ASIDE: blocked-on human` comment. Do not issue a new CHANGES_REQUESTED. The same step should have Renovate hold the PR until the prod pin moves, which the README's `agent/blocked` label already covers.
- Expected saving: about 6 reviewer rides per PR, which is cents on rail 3. The real saving is avoiding the `agent/error` summons, one out-of-sitting touch of about €20–30.

**F3 — The carved-out dependency lane cannot take a security bump that changes the lock graph.**
- Evidence: openrouter-operator#110 and #111. Both are armed security bumps, approved by the bot at 2026-11-06T22:41Z and 22:42Z. `ci` failed at the `deps-pin-guard` step on 2026-11-06T04:45Z, 13:40Z and 22:42Z, and the PRs are open. Standing stall is about 177,400 s each. #113 is the human-owned route issue. #111's coordinator ruling (2026-11-05T23:23Z) was "no worker dispatched, nothing merged".
- Mechanism: the pin-only guard rejects any `uv.lock` structural edge change. Security bumps often change edges (virtualenv gained a `packaging` edge). So these bumps always fail the check and need a human.
- Process change: add a scan clause that routes `security`+`automerge` PRs failing `deps-pin-guard` with "structure changed" to an owned-lock worker round, which is the route the guard message names. It would regenerate the lock and push, with no human summons.
- Expected saving: one out-of-sitting escalation per such PR, about €20–30 each, and security-fix latency. These PRs had waited more than 49 h by the window end.

**F4 — Spec-review rounds are used for mechanical row-tagging that the worker could pre-check.**
- Evidence: oracle-fleet#1021 / PR #1032, the final round (round 5 "fix" re-dispatch at 2026-11-08T18:33Z). The specs-reviewer's CHANGES_REQUESTED at 18:04Z asked only for ⚖ on the error-path row and a matching test param id. The same PR drew a code-reviewer approval at 18:01Z that is now DISMISSED. APPROVED came at 18:48Z and 18:50Z, then a merge. Rank-2 and rank-4 spec PRs (#1017, #1018) each took one more specs-review round-trip, including a CHANGES_REQUESTED on #1018 at 6c95566.
- Mechanism: the ⚖ and row-id convention is checked only after the PR opens, so one full round goes to a deterministic check.
- Process change: add a `specs row-tag` lint to the worker's local diff-ci recipe. It would check ⚖ presence and matching test param ids before the PR opens.
- Expected saving: about 1 round per spec-touching ride. That is small in euros, but it avoids ~45 min of wall time on this PR.

**F5 — Haiku first-touch rides are the only non-clean cohort.**
- Evidence: the ledger's `first_touch_by_model` shows haiku 2 tasks with 2 non-clean (homelab#3211 and #3222), versus sonnet 7 tasks with 1 non-clean. Both haiku rows end `agent/blocked`, `blocked-deliberate`, `worker-stop-report`, with $0 cost, which means untracked.
- Mechanism: haiku stops on tasks needing a judgment call (fixture re-pin on #3211), where sonnet continues. The n=2 is too small to say whether this is a model trait or tier mismatch.
- Process change: in `estimate_budget.py`, do not change the bands. Instead, record "judgment-required" (fixture re-pin or acceptance needing a human decision) as a routing signal to sonnet. Defer until at least 10 haiku rows.
- Expected saving: unquantified. Confidence is low.

**F6 — Capacity-blocked issues sit with no owner.**
- Evidence: homelab#3162 (kata-node memory queueing, AgentRunPhaseSlow pod-spinup 601 s) has been `agent/blocked` since 2026-11-03T05:00Z. Standing stall is 500,363 s, with no activity after the intake comment.
- Mechanism: capacity decisions have no sitting or batch slot. The ledger's wall times are idle-dominated, so they cannot size this.
- Process change: surface `blocked-on: human` capacity issues in the weekly retro batch list with an age number, so they go through one sitting rather than ad-hoc.
- Expected saving: a batched touch costs E/B. Confidence is low.

## Proposed process changes (table: change | artifact | expected saving | confidence)
| change | artifact | expected saving | confidence |
|---|---|---|---|
| Ruling that blocks dispatch writes a native `blockedBy` edge, and phantom-clear treats an open blocker as HOLD | README state machine / scan clause `agent/in-progress` | ~1 no-op round and one touch per park; €20–30 if out-of-sitting | medium |
| Reviewer posts one standing-aside when the same finding recurs on rebase-only heads | reviewer rubric | ~6 rides/PR (cents) plus one `agent/error` summons avoided (€20–30) | medium |
| Route `deps-pin-guard` "structure changed" security bumps to an owned-lock round | scan clause | ~€20–30 per PR, plus security latency | medium |
| Worker-side specs row-tag lint | recipe local diff-ci | ~1 round per spec ride, ~45 min wall | medium |
| Record "judgment-required" as a routing signal; no band change yet | `estimate_budget.py` | unquantified | low |
| Capacity-blocked issues listed in the batch sitting | retro-batch | E/B per issue | low |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)
- oracle-fleet#1021: chunked-right, as one task. The cost came from the gate, not the chunking (rounds 1 and 2 finished the change). Round 5 was one cross-artifact tag rework.
- oracle-fleet#1017 and #1018 (spec shape PRs): chunked-right. Each took 1–2 review round-trips, with no cross-chunk friction visible in the sampled events.
- oracle-fleet#1022: chunked-right, a single xs ride.
- sleep-tracking#218 and oracle-fleet#965: not a granularity problem. This is the same garage bump filed in two repos, and a shared pin policy would settle both.
- openrouter-operator#110, #111 and #113: should have been one owned-lock round (see F3), not three artifacts.
- Other ranks (homelab#3168, #3215, #3187, #1013 and similar): chunked-right. I did not deep-dive them.

## Wins to codify (or "none observed")
- Four first-round clean sonnet builds landed well under their caps and walls: oracle-fleet#1022 (xs, 679 s), #974, #924 (md, 664 s) and #999 (md, 631 s). The reusable procedure is a one-row spec edit plus a test param id under an existing row id, with a precise issue body. That is a recipe-text note for the xs and md tiers.
- Renovate automerge dep bumps (e.g. homelab#3215, openrouter-operator#105) merged in about 4–6 min with auto-approval and no worker. The coordinator's "not a major" ruling at openrouter-operator#105 and sleep-tracking#220 unblocked CI-flake cases quickly.

## Platform KPIs (bucket-A count · trend · proposed next gate)
- Bucket-A count: 5 distinct events this week. These come from trails and platform-repo issues, not the responder ledger, which I could not read.
  1. Phantom re-queue after a coordinator ruling (#1021).
  2. Reviewer loop at 4+ identical verdicts (#965).
  3. The same at 7 (#218).
  4. The `deps-pin-guard` lane mismatch (#110, #111).
  5. The agent-error latch on a human-blocked PR (#965, 2026-11-03).
- Trend: none computable, because `previous_findings` is empty in this bundle (22 total, not provided).
- Proposed next gate: a same-finding review-loop breaker. It would replay "N CHANGES_REQUESTED with an identical finding id on rebase-only heads → stop" as a scan-level test. This is the highest-recurrence unguarded class seen.

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")
Insufficient evidence. `previous_findings` is empty and `previous_findings_total` is 22, so I could not map earlier process changes to deployment.

## Evidence confidence (what you could NOT verify and why)
- `RETRO_GH_TOKEN` was set, and cross-repo reads worked.
- Trail evidence comes from first-hand reads of oracle-fleet#1021 and PR #1032, openrouter-operator#113, oracle-fleet#965, sleep-tracking#218, homelab#3214 and #3211, and the #1022 thread. These were bounded excerpts: bodies truncated at 250–900 characters and review lists cut by `head`. Counts are lower bounds. The remaining deep-dive ranks come from bundle events only.
- No spot-check of a first-approval one-round contrast beyond #1022's ledger row and bundle events.
- Worker transcripts and billed cost are not available. All dollar figures are unknown.
- The sampled event windows (8 per task) hide most middle events, so round counts are a lower bound.
- TOOL_GAP: responder-ledger read — needed for the bucket-A count and the trend; no responder ledger was reachable in this session.

BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[{"mechanism":"phantom-clear-requeues-after-environmental-ruling","surface":"agents/coordinator-scan.sh phantom in-progress clear + README state machine","summary":"A coordinator ruling that withholds dispatch on a cross-repo environmental cause should write a native blockedBy edge so the scan's phantom-clear does not re-queue and burn no-op rounds.","evidence":["https://github.com/teststuffstash/oracle-fleet/issues/1021","https://github.com/teststuffstash/homelab/issues/3214","https://github.com/teststuffstash/homelab/issues/3211"],"related_work":["https://github.com/teststuffstash/homelab/issues/3214"]},{"mechanism":"repeat-identical-changes-requested-on-rebase","surface":"reviewer rubric","summary":"After N>=2 identical findings at rebase-only heads, the reviewer should post one standing-aside blocked-on-human comment instead of a new CHANGES_REQUESTED each rebase.","evidence":["https://github.com/teststuffstash/sleep-tracking/pull/218","https://github.com/teststuffstash/oracle-fleet/pull/965"],"related_work":[]},{"mechanism":"deps-pin-guard-rejects-graph-changing-security-bumps","surface":"coordinator scan clause for armed security bumps","summary":"Route armed security bumps failing deps-pin-guard with structure changed to an owned-lock worker round instead of a human summons.","evidence":["https://github.com/teststuffstash/openrouter-operator/pull/110","https://github.com/teststuffstash/openrouter-operator/pull/111","https://github.com/teststuffstash/openrouter-operator/issues/113"],"related_work":["https://github.com/teststuffstash/openrouter-operator/issues/113"]},{"mechanism":"specs-row-tag-checked-only-after-pr-open","surface":"worker recipe local diff-ci","summary":"Add a worker-side lint for the specs row tag and test param id so the specs-reviewer round is not spent on a deterministic check.","evidence":["https://github.com/teststuffstash/oracle-fleet/issues/1021"],"related_work":[]}]}
```
END-RETRO-FINDINGS
