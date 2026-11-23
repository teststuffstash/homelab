# platform loop retro r13 — claude-opus-5-5 (Opus 5.5)

## Coverage (window, bundle identity, completeness, late corrections)
- **Window:** 2026-11-16T00:00:00Z → 2026-11-23T00:00:00Z (exclusive). Bundle `c75bed5eab1b775887dc7f130331d42ae49331aff4b37ea3a52f96314e042353`.
  - run_id r13, storage key `platform/runs/20261123T000000Z`, source revision `273e0ef`.
  - Collected until 2026-11-23T04:30:08Z; prepared 05:00:15Z.
  - Scope source: "live claims over committed mirror", 12 repos.
- **Whole-window population:** 395 tasks, 6,112 events, 261 failure events, 0 infra-failure events, 89 superseded cancellations, 52 worker-stat records, 51 dispatches.
  - Worker cost: `null` (0 measured records).
  - Rates below use this population, or the full in-window review set I enumerated (429 bot and human reviews on PRs updated in the window across homelab, oracle-fleet, sleep-tracking, circles and openrouter-operator). They never use the worst-K sample.
- **Completeness:**
  - Ledger: 35 rows were emitted, but only **22 were serialized**; 13 are missing because of the 60 KB byte cap.
  - Tasks: 21 selected, at most 8 events each.
  - `previous_findings`: 0 of 39 serialized. I read r12 directly from `docs/agents/retros/2026-11-16-platform-r12-opus.md`.
- **Ledger rows carry pre-window rounds.** The opencode-go/minimax first touches on homelab#2589, #1941 and #3087 (counted as 3/3 non-clean in `first_touch_by_model`) all ran on 2026-10-31 and 2026-11-01. Their trails show this (AGENT_STRIKE 2026-11-01T01:39Z, 2026-10-31T23:46Z, 2026-11-01T01:44Z). They are history for context, not in-window activity.
  - Their ~21-day `wall_time_s` is the fleet-fault latch on homelab#3095. That latch was un-latched automatically on 2026-11-22T06:59Z, and all three issues merged the same day.
- **Late arrivals:** 1,293 total, 20 serialized. All are dated 2026-08-30 to 2026-09-17 and were observed between 11-16 and 11-22. They are corrections to the Aug–Sep periods only and add nothing to this window's totals:
  - homelab#1101 closeout comments (2026-09-14)
  - oracle-fleet#619 labels and comments (2026-09-16)
  - sleep-iac#80 CI success (2026-08-30)
- **Ledger blind spots (stated once):** `reviewer_rounds`, `wall_time_s`, `retry_storms` and `total_cost_usd`=0.00 are unreliable, per FU-058. I counted review rounds from PR review trails and cross-checked wall times against PR open→merge times.
  - One further emitter gap seen in trails: homelab#3308's dead-pod rounds r1 and r2 (pods exited 255, finalize never ran) appear as no ledger round at all. Its row shows four clean rounds.

## Summary (≤5 lines)
1. Specs review is again the biggest round sink. It filed 32 CHANGES_REQUESTED verdicts on 21 PRs. **22 of the 32 are rule R10** (an expected cell with no source in the requirement prose), hitting **16 of 25** non-mechanical specs-reviewed PRs. These are defects the worker introduces, and they can be prevented at issue-authoring time. homelab#3654 → PR #3662 (approved first time in 10 min) shows how.
2. The specs reviewer reviews only after a code APPROVE (25/25 PRs), so 7 PRs found specs defects only after code rounds. On PR #3564 this breached the round bound and cost two operator-granted rounds.
3. Parks don't un-latch when the cause they cite clears: homelab#3501 (egress fixed 11-22, still `agent/blocked`), oracle-fleet#965 (#3663 filed for a human), oracle-fleet#1051. The #1539 un-latch only covers `agent/error` with a fleet-fault marker.
4. The reviewer re-reviewed `agent/blocked` oracle-fleet#1051 nine more times in the window. This is the third consecutive retro to report it, and the change has not deployed. The false-INFEASIBLE class (#3309) was fixed in-window (#3680/#3681); its effectiveness is unscored.
5. Bucket-A is ≥9 (r12: ≥8), counted from trails only. That is three runs without a fall, which makes the ADR-103 trigger (revisit label-carried loop state) a question for the operator.

## Findings (ranked, ≤6)

**F1 — R10 "cell without prose" accounts for most specs change requests; the worker introduces it, and the issue could prevent it.**
- **Evidence:**
  - In-window specs-reviewer CHANGES_REQUESTED: 32 verdicts on 21 PRs. R10 is in 22 of them, on 16 of the 25 non-mechanical specs-reviewed PRs: homelab #3560, #3564, #3585, #3590, #3614, #3615, #3620, #3635 and oracle-fleet #1097, #1099, #1100, #1102, #1106, #1107, #1108, #1110.
  - The next most frequent rule is R2 (the PR-body `Spec changes:` line), on 12 PRs.
  - Example: oracle-fleet PR #1108 (2026-11-21T23:42Z). The new row r49.1 states `period 10 s, failureThreshold 30` in its cells, but the prose names no startupProbe. Its issue #1033 said only "renders the startupProbe as stated", which points at text the review pack doesn't hold.
  - Each R10 verdict cost one fix round: a coordinator ARBITRATE ride, a worker ride and two re-reviews. A typical size is oracle-fleet PR #1110 round 4: 180,922 input tokens (+757,017 cached), 4,835 output tokens, 2,283 s.
- **Mechanism (falsifiable):** when an issue's Acceptance asks for a ⚖ row with concrete values but not the prose sentence that carries them, the worker writes the values only in cells. R10 fires on that every time.
  - Test: R10 should be near zero on PRs whose issue quoted the prose sentence verbatim. homelab#3654 → PR #3662, which touched catalog.md and wire.md, drew "Findings: none".
- **Process change:** add one rule to the issue-authoring recipe (`docs/agents/issue-authoring.md`, the lineage contract the brief cites). An Acceptance item that adds or changes a ⚖ row quotes the requirement-prose sentence carrying that row's values, verbatim, as #3654's Acceptance 1 does.
  - This differs from r11 F4 (a row-tag lint, never deployed) and from r12 F1 (scope creep onto unchanged rows). Here the rows are ones the PR itself adds.
- **Expected saving:**
  - Rail 1: R10 contributed to the PR #3564 round-bound breach (2 operator grants, about €25–35).
  - Rail 3: about 10–16 fix rounds per week. Cash-amortized ≈ $0 under headroom; at about 0.94 M input tokens per round, the API-equivalent is for the Go meter to price.

**F2 — Parks don't un-latch when the cause they cite clears; a human has to notice.**
- **Evidence:**
  - **homelab#3501:** parked `agent/blocked` 2026-11-17T00:50Z with `ci-cause: argocd-validate-pins/helm chart fetch class=environment`, after two strikes (11-16T23:46Z unknown, 11-17T00:32Z timeout). The park didn't cite the cause that was already open, homelab#3088 (open since 2026-10-31).
    - #3088, #3599 and #3667 closed 2026-11-22T06:39–07:09Z. #3501 is **still `agent/blocked` at observation time (2026-11-23)**, with its built branch `fix/issue-3501-gateway-release` waiting.
    - homelab#3604 hit the same wall on 11-20T22:38Z and needed a seat finish (#3624).
  - **oracle-fleet#965:** latched on a prod version window that cleared on 2026-11-13 (#3344). It was still latched in-window, and island intake filed homelab#3663 on 11-22 as a human act. #3663 records "the coordinator dropping `agent/error` by itself when the blocker a latch cites changes" as not filed.
  - **oracle-fleet#1051:** blocked since 11-12 on ADR-158's window. ADR-166 superseded that rule on 11-21, but nothing re-armed the PR. It merged only because the arbitrate cap fired (11-22T23:25Z).
  - Contrast: the #1539 un-latch worked. homelab#2589, #1941 and #3087 were un-latched 11-22T06:59Z when #3095 closed, and all three merged that day.
- **Mechanism:** the only machine-readable cause marker is the fleet-fault comment (`<!-- fleet-fault cause=… -->`) on `agent/error`. An `agent/blocked` park writes `blocked-on: human` plus prose, so the scan has nothing to re-check.
  - Test: every in-window park that cleared without a human had that marker.
- **Process change:** in the README state-machine row for `agent/blocked`, add one sentence. When the park's `ci-cause` is `class=environment`, or the blocker is an existing issue or ADR, the park comment carries `<!-- fleet-fault cause=<owner/repo>#<n> -->` (deduplicated to the existing issue). The FLEET-FAULT UN-LATCH (homelab#1539) then also removes `agent/blocked` and restores `agent/queued` when that cause closes.
- **Expected saving:** Rail 1: one out-of-sitting summons per stale park, about €20–30 each. Three occurred this window (#3501 pending, #965 via #3663, #1051 rescued by the cap), so about **€60–90 per week**. Latency: #965 sat about 9 days after its blocker cleared; #3501 is ≥17 h and counting.

**F3 — The specs reviewer runs only after a code APPROVE, so specs defects surface one or more rounds late.**
- **Evidence:**
  - In 25 of 25 non-mechanical specs-reviewed PRs this window, the first specs verdict came after a code-reviewer approval.
  - 9 PRs had code CHANGES_REQUESTED before the first specs verdict: homelab #3635 (3), #3564 (2), #3628, #3598, #3585, #3566, #3559 and oracle-fleet #1107, #1099. Seven of those then drew specs change requests.
  - **PR #3564:** code CR at 06:00Z and 07:41Z, code approve 08:09Z, then the first specs CR at 08:29Z (R10, R7 and R2 on GW-SESSIONS-ADMIT). The round bound ran out, and the operator granted round 6 (12:54Z) and round 7 (13:31Z) by hand.
- **Mechanism:** specs findings on rows present since the first head wait for code convergence, so code and specs rounds add up instead of overlapping.
  - Test: on those 7 PRs, the R10/R7 rows should already be present at the first head.
- **Process change:** the review reflex dispatches the specs reviewer at the first head together with the code reviewer, rather than after the code APPROVE. The worker then gets both verdicts in one fix round.
- **Expected saving:**
  - Rail 1: one avoided round-bound breach per week (PR #3564: one summons plus a second in-sitting grant, about €25–35).
  - Rail 3: about 5–7 rounds per week. This costs extra specs rides when code rounds change spec rows (cents).
- **Confidence:** low-medium. The ordering may be a deliberate cost choice.

**F4 — The reviewer re-reviews a parked PR on every Renovate rebase. Third retro in a row; extends r12 F5.**
- **Evidence:** oracle-fleet#1051 carried `agent/blocked` continuously from 2026-11-12T23:33Z.
  - The reviewer filed 9 in-window CHANGES_REQUESTED on identical one-line diffs: 11-17T01:57Z, 11-18T15:16Z, 11-20T00:27Z, 11-20T15:03Z, 11-20T23:55Z, 11-21T14:23Z, 11-21T23:02Z, 11-22T04:51Z, 11-22T14:12Z. Its own text says "the diff is identical and so is my verdict".
  - These reviewer-only verdicts tripped the cap of 12 (14 counted) and were logged as "a worker↔reviewer loop", although no worker ran.
- **Mechanism:** a rebase moves the head, and the reflex re-fires regardless of the park label. homelab#2147 fixed only the scan's ride fingerprint, not the reviewer.
- **Process change:** as in r11 and r12, the reviewer rubric skips PRs carrying `agent/blocked` or `agent/error` until a human removes the label, matching the README's "a human gate is never re-dispatched". Make it the next replay gate (see KPIs) so it can't silently fail to deploy a fourth time.
- **Expected saving:**
  - Rail 3: about 9 reviewer rides per week on this PR alone (cents).
  - It also stops cap-triggered arbitrations from misreading the situation as a worker↔reviewer loop.
  - Rail 1 only through F2's summons.

**F5 — Workers wrongly declare a task infeasible over footprint classification. Fixed for AGENT_INFEASIBLE; the AGENT_REPORT path is still open.**
- **Evidence:**
  - **homelab#3309 r1 (sonnet, 11-20T14:23Z):** AGENT_INFEASIBLE on `gateway/devbox.json`. The scan parked it. The operator's seat reversed it 52 h later (11-22T18:25Z): "only the ROOT `devbox.json` is codeowner-author".
  - **homelab#2589 (codex/gpt-6.1-terra, 11-22T07:17Z):** an AGENT_REPORT deliberate stop, "blocked by Touches", on `agents/replay/**`, which is an ADR-097 compelled counterpart. The coordinator overturned it at 07:21Z. The same false stop happened on haiku on 11-01 (history).
  - The fixes #3680 and #3681 (the scan verifies an AGENT_INFEASIBLE path with `classify_touches`) merged 2026-11-22T21:10–21:19Z, after both events.
- **Mechanism:** the worker reasons about footprint classes from prose instead of running `classify_touches`. #3681 checks only the AGENT_INFEASIBLE path; the #2589 shape was an AGENT_REPORT stop.
- **Process change:** no new issue for the fixed class; score #3680/#3681 at r14. Candidate residual: extend #3681's check to AGENT_REPORT deliberate stops whose report cites `Touches`/footprint.
- **Expected saving:**
  - Rail 1: about €5–8 in-sitting per false park (#3309), plus about 52 h of latency.
  - Rail 3: one coordinator plus one worker ride per false stop.

## Proposed process changes (table: change | artifact | expected saving | confidence)
| change | artifact | expected saving | confidence |
|---|---|---|---|
| An Acceptance item that adds or changes a ⚖ row quotes the requirement-prose sentence carrying its values verbatim (the #3654 shape) | `docs/agents/issue-authoring.md` (issue-authoring recipe) | rail 3: ~10–16 fix rounds/wk; rail 1: part of the PR #3564 breach (~€25–35) | medium |
| A park with `class=environment`, or one citing an existing issue/ADR, carries the `fleet-fault cause=` marker; the #1539 un-latch also clears `agent/blocked` → `agent/queued` | `agents/coordinator/README.md` state-machine rows for `agent/blocked` and `agent/error` (FLEET-FAULT UN-LATCH) | rail 1: ~€60–90/wk (3 stale parks) plus days of latency | medium |
| Specs reviewer dispatched at the first head together with the code reviewer, not gated on code APPROVE | review reflex dispatch (ADR-155 specs gate) | rail 1: ~€25–35/wk (one breach); rail 3: ~5–7 rounds/wk | low-medium |
| Reviewer skips PRs labelled `agent/blocked` or `agent/error`; enforced by a replay gate | reviewer rubric + reflex replay fixture | rail 3: ~9 rides/wk (cents); removes the misread cap trigger | medium |
| #3681's `classify_touches` check also covers AGENT_REPORT stops that cite Touches; score #3680/#3681 at r14 | scan AGENT_INFEASIBLE verify (homelab#3681) | rail 1: €5–8 plus ~52 h per false park; rail 3: 2 rides | medium |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)
- **homelab#3308 → PR #3564: chunked right.**
  - r1 and r2 were infra deaths (exit 255 during devbox startup, 11-13 and 11-16), and the issue was requeued by intake 11-20T05:05Z.
  - In-chunk work: 2 code rounds (cold-start robustness) and 2 specs rounds (R10/R7/R2, then E-HYGIENE_REPEAT).
  - No cross-chunk friction. The friction was serial review (F3).
- **oracle-fleet#1095 → PR #1107: chunked right.** The seat split the infra and platform halves into oracle-iac#1193 and a homelab handoff.
  - 4 fix rounds: 1 code (fail-open guard), 2 specs-content rounds, plus 3 body-only coordinator fixes (R2).
  - All in-chunk. The issue is left open per closeout rule 2 (live acceptance).
- **homelab#3563: chunked right.** One ride, a seat-authored one-line quota change (40Gi → 100Gi), 1 round. The experiment decides from 2026-11-27.
- **homelab#3586 (Goal: intake experiments): chunked right as a fan-out.** 8 of 9 descendants were closed at assembly (#3637, 11-21T18:31Z).
  - The one rework was #3604. It was built by the ride, but the `pr-open` egress wall (F2's #3088) forced a seat finish (#3624, three bot rounds plus a seat review). That was platform friction, not the chunk boundary.
- **oracle-fleet#1094 → PR #1102: chunked right, with cross-chunk friction.**
  - The sibling #1096 (PR #1100) reworded the same DEP-VERIFY legends in `specs/server/deploy.md`.
  - PR #1102 was DIRTY from 11-20T18:45Z to the seat's merge-only resolution at 11-21T13:48Z (one operator touch, about 19 h). In-chunk work was one specs round.
  - Siblings #1094, #1095 and #1096 all edit DEP-* legends; the shared-page edits should have been serialized with `blockedBy`.
- **homelab#3309: chunked right.**
  - Friction: a false INFEASIBLE (F5, 52 h), then PR #3590 specs rounds 2–3 (5 findings, then 1).
  - Still `agent/review` at observation, with follow-on PRs #3679, #3680 and #3681.
- **oracle-fleet#1051: not a chunking question.** A one-line Renovate pin that policy decided (ADR-158 → ADR-166). Its churn is F4, and its stale park is F2.
- **openrouter-operator#111: not a chunking question.** Operator lane by ruling (#113 closed 11-21T21:08Z).
  - I reproduced the guard locally: `scripts/deps_pin_shape.py uv-lock` returns rc=1 on the `platformdirs`→`packaging` edge that filelock 4.2.1 introduces.
  - It waits for virtualenv 21.15.11 (published 11-21) to pass the 7-day floor. Its 90,873 s standing stall is idle by design, and the 3 red CI runs are expected.

## Wins to codify (or "none observed")
- **homelab#3654 → PR #3662:** 10 min, 1 commit; both bots approved the first time, with real spec edits (catalog.md, wire.md, worlds/README) and "Findings: none".
  - Procedure: the Acceptance dictates the exact prose sentence to add, values included, and an exhaustive `Touches:` line.
  - Codify it as F1's issue-authoring rule.
- **The #1539 fleet-fault un-latch works.** The three latched issues were released the minute #3095 closed and merged the same day (PRs #3668, #3669, #3670). Generalizing it is F2.
- **Spec-free or docs-only children land first time.** homelab#3426 → PR #3671 was approved by both bots at first review (the codeowner's trim followed). This repeats r12's win.

## Platform KPIs (bucket-A count · trend · proposed next gate)
- **Bucket-A ≥9 distinct platform-logic events** (trail-derived lower bound; the responder ledger was not read):
  1. #3309 false AGENT_INFEASIBLE parked by the scan (11-20)
  2. #2589 false "blocked by Touches" stop (11-22)
  3. Reviewer re-review loop on `agent/blocked` oracle-fleet#1051; 9 verdicts counted as one event
  4. Arbitrate cap misread a reviewer-only loop as worker↔reviewer (oracle-fleet#1051, 11-22)
  5. `pr-open` egress wall on #3501 (11-16/17)
  6. The same wall on #3604 (11-20)
  7. #3308 r2 pod died with no AGENT_STRIKE or finalize (11-16)
  8. `agent/review` re-applied to the closed, `agent/done` oracle-fleet#902 (11-22T12:44Z; the scan reconciled it again at 12:54Z)
  9. #3426 intake repair session ended rc≠0 (11-22)
  - Plus the standing stale latch on oracle-fleet#965 (#3663).
- **Trend:** r11 5–6 → r12 ≥8 → r13 ≥9. The counting methods are mixed, so like-for-like is not established. This is the third run without a fall, so the ADR-103 trigger (revisit label-carried loop state) is flagged for the operator to judge, not asserted. F2 is that problem in miniature: park state lives in prose.
- **Proposed next gate: a replay gate for "reflex skips a parked PR".**
  - Fixture: a Renovate rebase on a PR carrying `agent/blocked` or `agent/error` produces no reviewer dispatch and no cap increment.
  - It covers the highest-recurrence unguarded class: 9 in-window events and 3 consecutive retros.

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")
I found no deployment of any r12 process change; searches of the homelab issues and PRs since 2026-11-16 turned up nothing. Status by r12 finding:
- **r12 F5 (reviewer skips parked PRs): not deployed, recurred.** 9 in-window verdicts on oracle-fleet#1051 → F4.
- **r12 F1 (unchanged rows go to Follow-ups):** not deployed. This window's dominant class is R10 on rows the PR itself added, which F1 would not catch → F1 re-targets authoring. **Insufficient evidence** for F1 itself.
- **r12 F2 (#3429, body-only no-op):** #3429 is still open. Opportunities did occur: 3 body-only R2 fixes on oracle-fleet PR #1107 and 1 on PR #3564's line. The coordinator resolved them itself ("body-only finding resolved") with no escalation. Since #3429 is undeployed, **insufficient evidence** that a fix caused this.
- **r12 F3 (blockedBy for registry files):** no multi-island registry opportunity. The nearest analogue is the shared DEP-* legends on oracle-fleet#1094/#1096 (one seat merge). **Insufficient evidence.**
- **r12 F4 (directives on the PR only):** not codified. Directives were still split: #3309's round-2 directive went on the issue. But the population has only 1 `agent-noop-rerun` and I saw no stale-directive no-op. **Insufficient evidence.**
- **r12 F6 (alternate-model first touch):** the only in-window alternate-model round was codex on #2589, non-clean (F5). The 3/3 opencode-go figure is pre-window. **Insufficient evidence.**
- **In-window deployed fixes to score at r14:** #3680/#3681 (false INFEASIBLE) and #3088/#3599/#3667 (`pr-open` egress). There have been no post-deployment opportunities yet.

## Evidence confidence (what you could NOT verify and why)
- **Ledger:** 13 of the 35 emitted rows were not serialized, so the ledger population counters are used as given. Rounds are undated, so I separated in-window rounds from history only through the trails.
- **Cost:** none available (worker cost `null`). Rail 2–3 savings are given in rides and tokens, without dollars.
- **Bucket-A** is a lower bound from GitHub trails. I did not read the responder ledger or `s3://agent-transcripts/`, so model-level retry loops inside sessions are unobserved.
- **F3:** I did not check whether the R10/R7 rows were present at the first head on all 7 serial-discovery PRs. Only PR #3564's sequence is traced in full.
- **F5:** I did not verify whether #3681's check covers the AGENT_REPORT shape (#2589); that is inferred from its title.
- **openrouter-operator#111:** `gh run view --log-failed` timed out on egress to the Actions log host. I worked around it by reproducing the guard locally against the PR's `uv.lock`, so verification was not affected.
- **Cross-repo access:** every stack repo I queried was reachable with the fleet read token (homelab, oracle-fleet, openrouter-operator, sleep-tracking, circles).

BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[{"mechanism":"specs-r10-cell-without-prose-worker-introduced","surface":"docs/agents/issue-authoring.md (Acceptance for ⚖ rows)","summary":"R10 (expected cell with no source in requirement prose) is 22 of 32 in-window specs-reviewer CHANGES_REQUESTED, on 16 of 25 non-mechanical specs-reviewed PRs; each costs a fix round. Proposed: an Acceptance item that adds or changes a ⚖ row quotes the prose sentence carrying its values verbatim (the #3654 → PR #3662 first-approval shape).","evidence":["https://github.com/teststuffstash/oracle-fleet/pull/1108","https://github.com/teststuffstash/homelab/pull/3564","https://github.com/teststuffstash/oracle-fleet/pull/1107","https://github.com/teststuffstash/homelab/pull/3620","https://github.com/teststuffstash/homelab/pull/3662"],"related_work":["https://github.com/teststuffstash/homelab/issues/3655"]},{"mechanism":"park-not-unlatched-when-cited-cause-clears","surface":"agents/coordinator/README.md agent/blocked row + FLEET-FAULT UN-LATCH (homelab#1539)","summary":"agent/blocked parks name their cause in prose only, so nothing re-queues them when it clears: #3501 is still blocked after #3088 closed 11-22; oracle-fleet#965 needed #3663; oracle-fleet#1051 stayed blocked after ADR-166. Proposed: environment-class or issue-citing parks carry the fleet-fault cause marker, and the #1539 un-latch also clears agent/blocked to agent/queued.","evidence":["https://github.com/teststuffstash/homelab/issues/3501","https://github.com/teststuffstash/homelab/issues/3663","https://github.com/teststuffstash/oracle-fleet/pull/1051","https://github.com/teststuffstash/homelab/issues/3604"],"related_work":["https://github.com/teststuffstash/homelab/issues/1539","https://github.com/teststuffstash/homelab/issues/3088","https://github.com/teststuffstash/homelab/issues/3599"]},{"mechanism":"specs-review-serialized-after-code-approval","surface":"review reflex dispatch (ADR-155 specs gate)","summary":"In 25 of 25 non-mechanical PRs the first specs verdict followed a code APPROVE; 7 PRs found specs defects only after code rounds, and PR #3564 breached the round bound, needing 2 operator-granted rounds. Proposed: dispatch the specs reviewer at the first head together with the code reviewer.","evidence":["https://github.com/teststuffstash/homelab/pull/3564","https://github.com/teststuffstash/oracle-fleet/pull/1107","https://github.com/teststuffstash/homelab/pull/3635","https://github.com/teststuffstash/oracle-fleet/pull/1099"],"related_work":[]},{"mechanism":"reviewer-re-reviews-parked-unfixable-pr","surface":"reviewer rubric","summary":"Recurred a third time: 9 in-window identical CHANGES_REQUESTED on agent/blocked oracle-fleet#1051 after Renovate rebases; the verdicts tripped the arbitrate cap, which logged them as a worker↔reviewer loop. Proposed: skip agent/blocked and agent/error PRs until a human removes the label, enforced by a reflex replay gate.","evidence":["https://github.com/teststuffstash/oracle-fleet/pull/1051"],"related_work":["https://github.com/teststuffstash/homelab/issues/2147"]},{"mechanism":"worker-false-infeasible-footprint-misread","surface":"scan AGENT_INFEASIBLE verify (classify_touches)","summary":"Workers stopped on wrong footprint rulings (#3309 nested devbox.json AGENT_INFEASIBLE, parked 52h; #2589 'blocked by Touches' on an ADR-097 compelled counterpart). #3680/#3681 fixed the AGENT_INFEASIBLE path on 11-22; the residual is extending the classify_touches check to AGENT_REPORT deliberate stops that cite Touches.","evidence":["https://github.com/teststuffstash/homelab/issues/3309","https://github.com/teststuffstash/homelab/issues/2589"],"related_work":["https://github.com/teststuffstash/homelab/issues/3680","https://github.com/teststuffstash/homelab/issues/3681"]}]}
```
END-RETRO-FINDINGS
