# platform loop retro r10 — Sonnet 5.5

## Coverage (window, bundle identity, completeness, late corrections)
- **Window:** 2026-10-19T00:00Z → 2026-11-02T00:00Z (exclusive), stack `platform`. Bundle `b50aa061…deaf`, storage key `platform/runs/20261102T000000Z`, source revision `54e93438`, collected until 2026-11-02T04:30:07Z.
- **Population:** 759 tasks and 10,814 events, of which 555 are failure events and 257 are superseded cancellations. Zero events are classed as infra failures. 24 tasks were sampled and 8 were deep-dived, though I drilled into more.
- **Ledger:** 38 task rows (7 snapshot rows) and 65 round entries.
  - Round outcomes: 27 clean, 13 failed, 7 timeout, 5 ci-failed, 4 infra-failure, 6 blocked-deliberate, 3 no-op.
  - Terminal labels: 32 `agent/done`, 6 `agent/blocked`.
- **Ledger blind spots (said once):** `reviewer_rounds`, the active/idle split of `wall_time_s`, model-level retry loops and zero-cost rows are unreliable. I counted review rounds from PR trails and did not use cost to judge calibration.
- **Wall-time cross-check:** the ledger and PR open→merge timestamps disagree strongly on #3048. The ledger says 63,420s (17.6h) and the PR was open 17.4h, but 7 reviews and 4 dismissals sat inside that, so it is mostly review idle.
- **Late arrivals:** 1,471 in total, only 20 shown, covering just two keys.
  - #538 is an Aug-18 alert that opened and cleared within 1h, observed 2026-10-20.
  - #818 is an Aug-23 goal-decompose trail, observed 2026-10-31.
  - Both belong to the August period. They count in no total here, and I can't correct the other ~1,450 without the collector artifact.
- **Ledger rows vs the window:** many ledger rows (ts 2026-11-01) describe rides from 2026-10-23/24, such as #2860/#2867/#2868. Those rides are inside the window but they surfaced in the ledger late.

## Summary (≤5 lines)
- Of 65 rounds, 38 (58%) did not end clean. Cheap first-touch models carry most of that: mimo 5/5 non-clean, glm 4/4, claude/haiku 4/5, minimax 2/3, against sonnet 2/13.
- 12 of the 13 "failed" rounds are one mechanism: the opencode-go ladder striking three times in about 5 minutes (4 tasks, all on 2026-10-23). The structural fix (#2870, merged 2026-10-24) landed after the evidence, so its effect is unproven.
- Two finished deliverables (#1563, #1571) were stranded on 2026-10-31 because the pod's egress couldn't reach a WAN-bound pre-PR gate. That cost an out-of-sitting operator summons, and it is still open.
- The python:3.15 bump hit 4 repos independently, and 76 of the 555 failure events (14%) sit on three of its PRs. One repo found the same musl wheel gap on 2026-10-29 that others hit separately.
- Dependency-bump and spec-doc rides are cheap and clean when routed to sonnet/haiku. Several 14-day "standing stalls" are deliberate holds, not failures.

## Findings (ranked, ≤6)

**F1 — The mis-dialect ladder burns 3 strikes before the first workable rung (partially fixed, effect unscored).**
- **Evidence:**
  - #2867 (strikes 2026-10-23T20:07/20:09/20:11), #2860 (17:57/17:58/18:00), #2868 (20:17/20:18/20:20) and agent-runtime#181 each took three strikes in order: mimo (no-output), glm (no-output), then opencode-go/claude-haiku-5-5 (nonzero-exit-1).
  - #2868's strikes read `unrecognized_model`, and #2870 records `Model does not support this pro…` for the claude-haiku rung.
  - That is 12 of the 13 "failed" rounds.
  - Only the fourth rung (claude/haiku) ran, and it ended `ci-failed` on three of the four tasks. #2867's fifth rung, codex/gpt-6-astra, then timed out.
  - The strike comments label the class `unknown`, while the ledger says `no-output` and `nonzero-exit-1`.
- **Mechanism:** the walk picked the harness before the cell, so models were struck for a dialect mismatch rather than for a model fault. The operator ruled on 2026-10-24 that the harness follows the cell; #2870 implemented it (PR #2883, merged 2026-10-24T11:22Z).
- **Process change:** add a replay fixture to the coordinator scan that asserts no two consecutive strikes share a rail+harness with `error_class=unknown`. Also make the strike emitter write a concrete `error_class` instead of `unknown`.
- **Expected saving:** about 15 min wall per affected task. Strikes are a subscription/API-rail cost of cents, so this is mostly latency. No operator-time saving is claimed.

**F2 — A WAN-bound pre-PR gate strands finished work as an out-of-sitting operator summons.**
- **Evidence:**
  - #1563 and #1571 each have a built, pushed and proven deliverable (comments 2026-10-31T23:07Z and 23:25Z).
  - The ride could not open a PR because the pre-PR gate needs WAN the pod's egress can't reach. Strikes landed at 23:08 and 23:27 with `egress-denied`.
  - FU-200 then latched both `agent/error` and filed fleet-fault cause #3091 at 23:28, which is still open (checked 2026-11-02).
  - #3016 and #2577 show the same class. #3016's strike is a side effect of an `AGENT_INFEASIBLE` ruling, so I don't count it.
- **Mechanism:** the pre-PR gate list includes at least one gate that needs WAN, and the egress policy denies it. The worker has no "open the PR without that gate and flag it" route, so it ends as a strike.
- **Process change:** add an explicit `WAN-bound` skip-and-flag path to the worker recipe's pre-PR gate step. The worker would open the PR with the gate named as unrun and let CI run it, rather than striking.
- **Expected saving:** one out-of-sitting summons per stranded pair, about €20–30 each. At least €40–60 for these two. The saving only holds if the unrun gate is run later by CI.
- **Note:** both are PR-less issue latches, the exact class #3048 fixed (PR #3096, merged 2026-11-01T20:52Z). They should auto-un-latch when #3091 closes, so don't refile.

**F3 — Cheap first-touch tiers have high non-clean rates on build rides.**
- **Evidence (first-touch non-clean):**
  - mimo-v2.6-flash 5/5
  - glm-5.3-flash 4/4 (two rows: opencode-go and z-ai)
  - minimax-m3.1-flash 2/3 (both are #1563/#1571's egress-denied, so it is not a model fault)
  - claude/haiku 4/5
  - deepseek-v4.1-flash:exacto 1/3
  - sonnet 2/13, both of which were deliberate stops that resumed cleanly
  - Rows with a clean first round: #988, #981, #984, #939, #951.
- **Mechanism:** the cheap rails time out or fail outright on multi-file edits. #2870 is the worked example: mimo timed out three times (rounds 1, 2, 4) and the branch was resumed each time before a clean round 4.
- **Process change:** in the recipe's model-selection section, route tasks above the `sm` tier straight to the sonnet rail for round 1, with the cheap rail kept only for `xs`/`sm`. This is a candidate, and it needs a cost view the ledger can't give.
- **Expected saving:** unknown in dollars (cost is untracked). In wall time it saves about 2 failed cheap rounds per `md` task, roughly 30–60 min.
- **Confidence:** low-to-medium. The sample is small and confounded by F1.

**F4 — The python:3.15 bump is rediscovered per repo.**
- **Evidence:**
  - homelab#2610 (opened 2026-10-16, merged 2026-10-28T09:42Z; 101 events, 32 failure events).
  - oracle-fleet#883 (2026-10-16 → 2026-10-28T16:32Z; 108 events, 30 failure events).
  - circles#124 was closed as superseded on 2026-10-28 after two review rounds, by #129 (python 3.15.0 final across devbox/pyproject/uv.lock).
  - allure-behavior-snippets#36 is still open and parked. On 2026-10-29 `ARBITRATE` diagnosed that `zstandard` has no 3.15 musl wheel and pip builds from source. Auto-merge was disarmed 2026-10-31T20:50Z, and the build is still red on 2026-11-01.
- **Mechanism:** Renovate opens the same major bump in each repo, and each one's CI finds the wheel/toolchain gaps on its own. The homelab/oracle runs had 12 days of churn.
- **Process change:** add a Renovate `packageRule` (in `renovate-global.json`) that holds `python` docker-tag majors until a homelab-repo canary PR is green, and hold the rest to match. The existing `major` marker covers the review path, but not this ordering.
- **Expected saving:** about 3 PRs × 12 days of repeated CI, plus avoidable review rounds. Operator time is probably €3–8 per PR in-sitting.
- **Confidence:** medium. The rule's exact form is unverified.

**F5 — `ci-failed` is the dominant failure on claude/haiku rides after the ladder falls through.**
- **Evidence:**
  - #2860, #2867 and #2868 all ended `ci-failed` on their claude/haiku round, and the PRs still merged (2026-10-23, 25 min / 68 min / 15 min after open, with 3 / 3 / 2 commits).
  - #2868 and #2860 were spec-doc tasks (`sessions.md` operation column, GW-REDACT rule 11).
- **Mechanism (untested):** haiku produces the doc change, but the spec-process lint (rule 11, "header == parameter list") catches it, so CI red is a correction loop rather than a defect.
- **Process change:** add the spec-lint command to the recipe's "before you push" step for spec-doc tasks.
- **Expected saving:** one CI-red round per spec-doc task. This is rail 3, so cents, not euros.
- **Confidence:** low. I did not read the CI logs.

**F6 — Several "standing stalls" are deliberate holds, not failures (don't act).**
- **Evidence:** oracle-fleet #826, #865, #866 and #820 each show 14 days (1,209,600s) of stall. #826/#865/#866 are `agent/done` but open on purpose: #865 and #866 were reopened for measurement follow-ups, and #826 awaits an A/B run. #820 was parked by operator ruling on 2026-10-13 ("drop the code, keep it on a branch, keep this issue open").
- **Process change:** none. This is a note so the next retro doesn't rank them again.

## Proposed process changes (table: change | artifact | expected saving | confidence)
| change | artifact | expected saving | confidence |
|---|---|---|---|
| Replay fixture: no consecutive same-harness strikes with `error_class=unknown`, plus concrete strike classes | `agents/coordinator-scan.sh` fixtures | ~15 min wall per affected task; no operator time | medium |
| WAN-bound pre-PR gate: skip-and-flag instead of strike | worker recipe, pre-PR gate step | ~€20–30 per out-of-sitting summons avoided (≥€40–60 here) | medium |
| Route >`sm` tiers to sonnet on round 1 | recipe model-selection | unknown in $; ~30–60 min wall per `md` task | low |
| Hold cross-repo python majors behind a homelab canary | `renovate-global.json` packageRule | ~€3–8 per PR in-sitting; 12 days of repeated CI | medium |
| Spec-lint in the pre-push step for spec-doc tasks | recipe "before you push" | 1 CI-red round per task (cents) | low |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)
- **homelab#2610 / oracle-fleet#883 / circles#124 / allure#36 (python 3.15):** should have been one task, or one canary plus fan-out. Four independent PRs found the same toolchain gaps over 12+ days, and circles' two rounds were superseded.
- **homelab#2819 (crossplane 2.4.3):** chunked right. It merged with the `agent/blocked` label cleared later (2026-10-31T12:34Z). The linked #2821 is a Renovate grouping bug, not a task-split problem.
- **sleep-tracking#199 (lock-file maintenance):** chunked right but long-waiting. The fix round applied cleanly at 2026-10-19T04:07Z, then the PR sat 14 days under a Renovate "Edited/Blocked" notice (1,166,846s stall).
- **oracle-fleet #950 / #977 / #978 / #975 (snapshot-contracts goal):** chunked right. #978 and #975 each took one round, merged into the goal branch (#979 / #980) and were closed by the FU-143 closeout. Assembly #977 merged at 2026-11-01T18:36Z. The one rework was #974/#976's spec follow-ups.
- **homelab#3048 (un-latch):** should have been one larger task. 7 rounds, 8 reviews with 4 dismissed, and phantom `agent/in-progress` clears at 01:31 and 03:01. Two ARBITRATE rides were needed before PR #3096 opened. A first-round ride ended without committing.
- **homelab#1973 / PR #3093:** mixed. Five rounds (haiku → sonnet → opus no-op → alt-haiku no-op → opus clean) for a small SA fix. The cheap rails couldn't deliver, and opus finished it.
- **homelab#2768 (rail-served ids):** blocked on an operator ruling, with nothing for a worker to chunk.
- **homelab#2273 (goals), oracle-fleet #820/#826/#865/#866:** no work in the window (see F6).

## Wins to codify (or "none observed")
- **oracle-fleet #984 and #981 (sonnet, `xs`/`sm` tiers):** one round, 820–961s wall, spec-only. #988 (`xs`) was two clean rounds. A reusable recipe would be "spec-only rows on the sonnet rail, tier `xs`/`sm`, tombstone-style edits". The pattern is tiny, row-shaped changes.
- **#978 and #975 on the goal-branch flow (goal/950-snapshot-contracts):** both finished in 1 round and closed automatically via the FU-143 closeout. That goal-branch plus closeout path is worth keeping as the default for child tasks.
- **Fleet-strike detection (FU-200):** it caught #1563/#1571 within 20 min of the second strike, so it works as designed.

## Platform KPIs (bucket-A count · trend · proposed next gate)
- **Bucket-A count:** I could not recompute a clean number from this bundle. The responder ledger isn't included, and `agent_pain_events` is 43 across the window. Platform-logic events I can name from trails: #3048's un-latch hole (fixed 2026-11-01), the phantom `agent/in-progress` clears on #3048 (01:31, 03:01), and the F1 harness/dialect walk (fixed 2026-10-24). That is 3 distinct classes, all with a fix already merged.
- **Trend:** no prior comparable (see predecessor score). The classes above all got a fix in the window, which is the direction ADR-103 wants.
- **Proposed next gate:** the F1 replay fixture (no consecutive same-harness unknown-class strikes). It is the highest-recurrence unguarded class this window (12 of 13 failed rounds).

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")
- `previous_findings` is empty in the bundle, though `previous_findings_total` is 21, so I cannot score specific past recommendations.
- Two fixes did land inside the window and can be scored on opportunities after deployment:
  - #2870 (harness follows the cell, merged 2026-10-24T11:22Z). Post-merge opportunities: #3011 (2026-10-29) failed on a different rail (`z-ai/glm-5.3-flash` no-output, then `opencode-go/glm-5.3-flash` timeout), and #2577/#3016 failed with egress-denied. None show the old ladder-of-three pattern. **Insufficient evidence to call it effective**, because I saw no post-merge task that would have hit the old failure.
  - #3048 (un-latch for PR-less issues, merged 2026-11-01T20:52Z). #1563/#1571 are the opportunity, but #3091 is still open, so the un-latch can't fire yet. Insufficient evidence.

## Evidence confidence (what you could NOT verify and why)
- `RETRO_GH_TOKEN` was set and plain `gh` worked on `teststuffstash/homelab`, oracle-fleet and allure-behavior-snippets. I did not open circles, sleep-tracking or agent-runtime trails and rely on the bundle for those.
- I did not read CI logs (F5 is a hypothesis), the worker transcripts, or the collector state artifact. The latter would give the full late-arrival list and cost data.
- The 12 ledger failures in F1 come from the ledger rows plus three trails (#2860/#2867/#2868). agent-runtime#181 is ledger-only.
- Dollar costs are unavailable: ledger cost is 0.00 on nearly every row (untracked), and only one measured record ($0.0144) exists in the window.
- TOOL_GAP: responder-ledger read — needed to compute the bucket-A count exactly; it is not in the bundle.
- TOOL_GAP: collector state artifact — needed to see the ~1,450 late arrivals beyond the 20 shown.
