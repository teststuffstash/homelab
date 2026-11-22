# platform loop retro r12 — claude-opus-5-5

## Coverage (window, bundle identity, completeness, late corrections)
- **Window:** `2026-11-09T00:00:00Z` → `2026-11-16T00:00:00Z`, exclusive (`window.since/until`).
- **Bundle:** `4bd55bdf84eb…2b3e`, run `r12`, series `platform`, source revision `7c7399df`.
  - Collected until 2026-11-16T04:30:08Z; prepared 05:00:09Z.
  - Storage key `platform/runs/20261116T000000Z`.
- **Whole-population counts used for every rate:**
  - 392 tasks, 7,814 events, 311 failure events, 0 infra-failure events, 110 superseded cancellations.
  - 88 worker-stat records. Only 2 of them carry a measured cost ($0.0521).
- **Ledger population:** 38 rows emitted.
  - 77 round entries: 60 clean, 5 no-op, 7 blocked-deliberate, 2 failed, 2 ci-failed, 1 input-unreadable.
  - Terminal labels: 30 `agent/done`, 8 `agent/blocked`.
- **Completeness:**
  - Only **21 of the 38 ledger rows** were serialized (the bundle's 60 KB cap). Per-row claims cover those 21; every rate uses the population counters.
  - 20 of 40 possible tasks were selected, with at most 8 events each. Trails were drilled through `gh`, which was fully reachable across homelab and oracle-fleet.
- **Ledger caveats (stated once):** treat these fields as unreliable throughout.
  - `reviewer_rounds = 0`, so review rounds are counted from the PR trails.
  - `wall_time_s` is not split into active and idle time.
  - `retry_storms` counts harness-level retries only.
  - `$0.00` on subscription rows means untracked, not free.
- **Snapshot staleness (not one of the known blind spots):** rows for homelab#3258 and #3180 say `OPEN / agent/blocked`. Both issues actually closed `agent/done` on 2026-11-11 (22:56Z and 23:12Z). Snapshot rows lag issue state.
- **Late arrivals:** 465 observations (20 serialized). They correct earlier periods, for example homelab#1643 (2026-09-13/16, observed 2026-11-12) and sleep-iac#80 (2026-08-30). None of them changes an r12 window total.

## Summary (≤5 lines)
1. Specs review burns the most rounds and the most operator time. It filed **39 of 52** CHANGES_REQUESTED verdicts on the 21 agent PRs in the window, and 17 of 21 PRs drew at least one. On #3450 and #3337 the round budget ran out on spec text and the operator finished the commits by hand.
2. Coordinator directives were posted on both the issue and the PR. On #3396/#3415 three rounds (r4, r7, r8) were no-ops because the worker read the stale surface.
3. Three concurrent island Goals each added a positional row to `scripts/diff-ci.sh`. That caused assembly conflicts on PRs #3416 and #3418, which the operator merged by hand (9 operator commits).
4. Win: spec-free code children land on the first round (oracle-fleet PR #1081: 18 min, 0 change requests). Goal oracle-fleet#1060 was **validated on real traffic**.
5. Bucket-A is **≥8**, up from 5–6 in r11. None of r11's process changes deployed, and its F2 class recurred on oracle-fleet#1051.

## Findings (ranked, ≤6)

**F1 — The specs reviewer's findings expand every round, so the round bound runs out on spec text and the operator finishes by hand.**
- **Evidence:**
  - **PR #3450 (issue #3449):** the specs reviewer filed 6 CHANGES_REQUESTED in 3.5 h (17:24Z → 20:32Z, 2026-11-15).
    - Each verdict named new finding ids on rows the diff had not touched: R10 on SCAN-CLAUSE-FLEET, PHANTOM and QUEUED, then E-NO_EVIDENCE on SCAN-GH-ONE-BLOCK.
    - The coordinator ruled them "out of scope" in round 3 (17:30Z). In round 5 (17:58Z) it reversed itself: "the page-preamble change put the WHOLE page in scope… round 3's ruling is superseded".
    - #3449 went `agent/blocked` at 18:14Z. The operator pushed `78edb684` and `db13e8dd` by hand, and the PR merged at 20:42Z.
  - **PR #3337 (issue #3302):** 4 specs-reviewer CHANGES_REQUESTED. Escalated on 2026-11-13 at 04:34Z, then ~62 h idle until 2026-11-15 at 18:55Z. The operator committed twice by hand (19:40Z, 20:09Z) before merging at 20:28Z.
  - **Specs-text rounds dominated other in-window tasks:**
    - #3396: 10 ledger rounds.
    - #3301: rounds 3–5 were specs fixes (PR #3324, 3 specs change requests).
    - #3306: round 4 was "one prose sentence" (PR #3327, 2 specs change requests).
- **Mechanism (falsifiable):** each specs-review pass re-reads the whole page. Anything it newly notices on unchanged rows is filed as blocking. No rule makes the blocking set shrink over successive rounds, so the reviewer cannot converge within 5 logic rounds on large spec pages.
  - Test: the share of each round's blocking ids that are new and sit on rows untouched since the first verdict should be high on #3450 and #3337 and near zero on PRs that converged.
- **Process change:** add one sentence to the specs reviewer rubric (ADR-155) for round 2 onwards.
  - A finding on a row that is unchanged since the reviewer's first verdict on the PR goes under `Follow-ups:`, not blocking. The exception is a regression the PR itself introduced.
  - This replaces the rule the coordinator applied on #3450: "a finding the pack put in scope still blocks".
- **Expected saving:**
  - Rail 1: two hand-finishes this week (#3450, #3337). One of them followed a 62 h escalation idle, i.e. an out-of-sitting touch. That is about €20–30 plus about €5 in-sitting, roughly **€25–35 per week**.
  - Rail 3: about 6–8 sonnet subscription rounds per week (cash-amortized ≈ $0 under headroom; API-equivalent unmeasured).

**F2 — Specs-reviewer verdicts that a body-only fix should satisfy cause no-op rounds and escalations. This extends #3429; do not file a new issue.**
- **Evidence:**
  - #3337 round 4: the directive (2026-11-13T03:36Z) was a PR-body edit. The round made no push, so it counted as a no-op. The re-run (04:03Z) was also a no-op, which triggered escalation (04:34Z) and ~62 h of idle time.
  - oracle-fleet#1082 (2026-11-15): the operator had to un-wedge it by hand. This is the case homelab#3429 (open, filed 2026-11-15) describes.
- **Mechanism:** the README defines a no-op as "stats posted, HEAD unmoved". A round whose only correct action is a body edit is therefore a no-op by construction, and the specs reviewer's `own-at-head` classify never re-reads the body.
- **Process change:** add the #3337 shape as a second case to #3429. Amend the README invariant so a no-op is "stats posted, HEAD unmoved **and the PR body unedited since the directive**".
- **Expected saving:** one out-of-sitting escalation per occurrence (about €20–30). Two occurred this week, so about **€40–60**, plus about 62 h of latency on #3302.

**F3 — Concurrent island Goals all write positional rows into `scripts/diff-ci.sh`, and the conflict lands in the operator's assembly lane.**
- **Evidence:**
  - The scan, launch and retro islands (Goals #3389, #3390 and #3384, launched in the 2026-11-14 night run) each add one `scripts/diff-ci.sh` MAP row (#3391).
  - Assembly PR #3416: 4 operator commits (2026-11-15T16:01Z–18:48Z), including "diff-ci.sh conflict" and "the launch island's row moves off the spot master's retro row".
  - Assembly PR #3418: 5 operator commits (16:11Z–20:52Z).
  - Related gaps: #3442 (open) is a diff-ci trigger gap, and #3391 is `agent/blocked` in the operator-only `ci.yaml` lane.
- **Mechanism:** the ADR-097 footprint is released when a PR opens, and Goal branches isolate siblings from each other. Edits to the same file across Goals therefore surface only when each Goal is merged into master, i.e. after automation has finished.
- **Process change:** following the README rule that "dependencies are native GitHub `blockedBy` edges", an island launch whose children's `Touches:` names a shared registry file (`scripts/diff-ci.sh`) gets a `blockedBy` edge from each sibling Goal's registry child to the first one. The registry edits then rebase in sequence rather than conflict at assembly.
- **Expected saving:** Rail 1, about 3 in-sitting conflict resolutions at €3–8 each, so **€10–25 per multi-island launch**. Confidence low-medium; launches like this are rare.

**F4 — ARBITRATE directives split across the issue and the PR, so workers execute a stale one and the round is a no-op.**
- **Evidence:** #3396 / PR #3415 on 2026-11-15.
  - Directives were posted on the issue (00:48Z r3, 01:07Z r4 supersede, 01:23Z r6, 02:04Z r9) and on the PR (00:35Z r2, 01:02Z r4, 01:15Z r5, 01:35Z r7).
  - The coordinator's own words: "round 4 no-op'd on [the stale directive]"; "Rounds 7 and 8 were no-ops because the worker read the stale round-6 directive on this issue instead of the round-7 directive posted on the PR".
  - Ledger: #3396 has 3 of the window's 5 no-op round entries. The population shows 4 `agent-noop-rerun` events.
- **Mechanism:** the #1910 re-run contract says a directive may sit "on the PR or its issue". The worker takes the newest directive on one surface, not the newest across both.
  - Test: every stale no-op should have a newer directive on the other surface.
- **Process change:** add to the README invariants: once a PR is open, ARBITRATE directives go on the PR only, and the issue gets only a pointer line. This is the form the coordinator already used on #3449 at 17:30Z ("round 3 directive is on PR #3450").
- **Expected saving:** Rail 3 only, about 3 worker rounds and 2 coordinator rides per occurrence (cents amortized), plus about 1 h of wall time. No operator touch this week. Stated honestly.

**F5 — The reviewer keeps re-reviewing a parked PR whose blocker no fix round can change. This recurs r11 F2, which never deployed.**
- **Evidence:** oracle-fleet#1051 (prom/prometheus v3.16.0).
  - 5 identical CHANGES_REQUESTED (2026-11-12T23:24Z, 11-13T13:10Z, 13:49Z, 14:05Z, 11-14T22:15Z), all on the same version-window finding.
  - Four of them came after `agent/blocked` was set (2026-11-12T23:33Z).
  - A coordinator ride ruled "not adaptable on this branch".
  - The bundle shows 4,924 s of standing stall in the window.
- **Mechanism:** a Renovate rebase moves the head, so the reviewer re-fires even though the PR is parked.
- **Process change:** as in r11, the reviewer rubric should skip PRs carrying `agent/blocked` until a human removes the label. The README already defines that label as "a human gate is never re-dispatched".
- **Expected saving:** Rail 3, about 4 reviewer rides (cents). It would also prevent an eventual `agent/error` summons (about €20–30). Confidence medium.

**F6 — First-touch rides on non-sonnet models are mostly non-clean.**
- **Evidence:** ledger `first_touch_by_model`. Non-sonnet first touches were non-clean on **4 of 5** tasks:
  - haiku 2/2: #3180 `no-output`, #3191 `worker-stop-report`.
  - codex-sol 1/1: #3258 stop-report.
  - codex-terra 1/1: #3395 `rate-limit` / input-unreadable.
  - deepseek-flash 0/1.
  - By comparison, sonnet / claude/sonnet were non-clean on **5 of 32**.
  - r11 also measured haiku at 2/2, so the haiku cohort is now 4/4 across two windows.
- **Mechanism:** alternate models get first touches without regard to task class, and each failure costs a strike plus a model swap.
- **Process change:** in `estimate_budget.py` model selection (`lookup_ids`), route `task/build` first touches to the stack default until an alternate model has at least 10 ledger rows. No change to the bands.
- **Expected saving:** Rail 3, about 4 swap rides per week. #3180 and #3191 were also parks (possible rail-1 touches). Confidence low (n = 5).

## Proposed process changes (table: change | artifact | expected saving | confidence)
| change | artifact | expected saving | confidence |
|---|---|---|---|
| From round 2, findings on rows unchanged since the first verdict go under `Follow-ups:` unless they are regressions the PR introduced | specs reviewer rubric (ADR-155) | ~€25–35/wk rail 1 (2 hand-finishes, 1 out-of-sitting) + 6–8 subscription rounds | medium |
| No-op means "HEAD unmoved **and body unedited since directive**"; add #3337 to #3429 | README invariants / homelab#3429 | ~€40–60/wk (2 escalations) + 62 h latency | medium |
| Registry-file `Touches:` across sibling Goals gets native `blockedBy` edges | README §Dependencies (blockedBy) at island launch | €10–25 per multi-island launch (in-sitting merges) | low-medium |
| With a PR open, ARBITRATE directives go on the PR only, with a pointer on the issue | README invariants (#1910 contract) | rail 3 only: ~3 rounds + 2 rides per occurrence, ~1 h wall | high |
| Reviewer skips `agent/blocked` PRs on rebase | reviewer rubric | cents + one avoided `agent/error` summons (~€20–30) | medium |
| Default-model first touch for `task/build` until an alternate model has ≥10 rows | `estimate_budget.py` (`lookup_ids` routing) | ~4 swap rides/wk; possible park avoidance | low |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)
- **homelab#3389 (Goal: scan island):** chunked right for code, but the shared spec page should have been one.
  - Build children landed in 3–4 rounds each (#3395 4, #3397 3).
  - The shared `scan-decision.md` page was edited by several children. Assembly specs review then created two rework children: #3449 (5 rounds plus operator commits) and #3463.
  - Integration friction: ≥7 rounds plus about 5 operator commits, against in-chunk work of about 3 rounds per child.
- **homelab#3449 / PR #3450:** should have been one.
  - This is a spec-only rework child. Its scope grew mid-ride, from the six findings in the issue to the whole page.
  - One ride with whole-page scope from the start (larger model, the page as the unit) would have avoided rounds 3–5.
  - All 5 rounds plus the hand-finish were in-chunk spec text.
- **oracle-fleet#1060 (Goal: MCP modern era):** chunked right.
  - Children #1062, #1064, #1067 and #1072 took 1–2 rounds each. #1061 took 6 rounds (3 specs change requests on PR #1068).
  - The only integration friction was the body-only wedge on assembly #1082 (F2).
  - Validated by a real-traffic verdict on 2026-11-15T19:44Z.
- **homelab#3415 (PR for #3396):** chunked right.
  - Of 9 rounds, 3 were directive-surface no-ops (F4) and the rest were one-cell spec edits. The friction came from the loop's mechanics, not from the chunk boundary.
- **homelab#3301 (GW-WIRE-RECORD/VIEW):** chunked right.
  - 5 rounds: the build was clean, and rounds 3 and 5 were specs-text fixes (PR #3324). The friction is in-chunk F1, not cross-chunk.
- **homelab#3390 (Goal: launch island):** chunked right inside the Goal.
  - Cross-Goal friction on `scripts/diff-ci.sh` (F3): 4 operator commits on #3416.
  - Post-assembly rework children: #3446 and #3457.
- **homelab#3450:** see #3449.
- **oracle-fleet#917 (deploy: rollout engine):** a mixed agent/operator item; the chart half was the right chunk.
  - Round 1 stopped deliberately (2026-11-11T21:04Z) because of an in-pod kind e2e timeout. Round 2 ended in a strike (exit 143).
  - The rest of the in-window activity was operator Kargo rung work.
  - Standing stall in the window: 270,905 s (~75 h). That is idle time waiting on the operator lane, not agent slowness.

## Wins to codify (or "none observed")
- **oracle-fleet#1067 → PR #1081** landed in 18 min with 1 commit (2026-11-14T23:38Z → 23:56Z). Both reviewers approved first time, and the specs reviewer reported "Findings: none".
  - Reusable procedure: the issue body carried the exact artifact (an `experiment` block, compared byte-for-byte by the reviewer).
  - The child touched **no `specs/` path** ("Spec changes: none"), so specs review was a single pass.
  - **Codify in the issue-authoring recipe:** a code child carries no edits to shared spec pages. All of a Goal's shared-page edits go into **one** spec-owner child, which addresses F1 and the integration friction on #3389.
- **Goal oracle-fleet#1060:** first metric verdict of the factory loop, decided by `release-observe` on real traffic. The closeout on 2026-11-15T19:56Z needed one operator line.

## Platform KPIs (bucket-A count · trend · proposed next gate)
- **Bucket-A: ≥8 distinct platform-logic events (a lower bound; the responder ledger was unreachable).**
  1. Stale-directive no-op on #3396 r4 (2026-11-15).
  2. Stale-directive no-ops on #3396 r7–r8 (2026-11-15). Same mechanism, but a separate event after a supersede comment failed to prevent it.
  3. #3337 body-only directive no-op and escalation (2026-11-13).
  4. oracle-fleet#1082 specs-reviewer body-only wedge (#3429, 2026-11-15).
  5. ci-red lane ruled 12× with no worker round on PR #3400 (#3426).
  6. In-pod gate reported `ci_passed` because `lock-intake-lint` is PR_ONLY (#3427).
  7. Reviewer re-reviewed a PR already `agent/blocked` 4× (oracle-fleet#1051).
  8. Coordinator reversed its own scope ruling, which burned the round bound on #3450.
- **Trend:** reported cells run 13 → 13 → 14 → 8 → 6 (r11: ≥6 per Kimi, 5 per Sonnet) → **≥8**. That is a rise, but the counting methods are mixed (trail-only, lower bound), so like-for-like is not established.
  - Two consecutive runs without a fall moves toward the ADR-103 sustained-non-fall trigger (revisit label-carried loop state). Flagged for operator judgment, not asserted.
- **Proposed next gate:** a **directive / no-op replay gate**, covering the highest-recurrence unguarded class this week (events 1–4). Replay fixtures assert that the launcher hands the worker the newest line-anchored ARBITRATE across the PR and the issue. A body-only directive must not be classified as a no-op.

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")
- I found **no deployment of any of r11's six process changes** (searched teststuffstash issues and PRs since 2026-11-09). So there is nothing to score for effectiveness. Recurrence on post-r11 opportunities:
  - **r11 F2 / next gate (same-finding review loop): recurred** on oracle-fleet#1051 (5 identical change requests, 2026-11-12 → 11-14). Not deployed; carried forward as F5.
  - **r11 F4 (worker-side specs row-tag lint): not deployed.** The opportunity grew: specs change requests now average about 1.9 per agent PR (39/21), and they caused two hand-finishes. F1 re-targets the reviewer rubric because the findings this week (R10 / E-NO_EVIDENCE on unchanged rows) are not row-tag mechanics a lint would catch.
  - **r11 F3 (owned-lock route):** openrouter-operator#113 is still open, and no in-window opportunity appeared. **Insufficient evidence.**
  - **r11 F1, F5, F6:** F6 (haiku) has two more non-clean rows (n now 4/4). F1 and F5 had no in-window opportunity. **Insufficient evidence.**

## Evidence confidence (what you could NOT verify and why)
TOOL_GAP: s5cmd (`s3://agent-transcripts/`, collector state) — needed for the 17 unserialized ledger rows and to check for model-level retry loops inside sessions; the read timed out after 30 s.
TOOL_GAP: responder ledger — needed for a complete bucket-A count; no in-pod read path, so ≥8 is a lower bound.
- I did not check the causes of the no-op rounds on #3307 and #3395. Only the no-ops on #3396 (stale directive) and #3337 (body-only) are attributed.
- No costs are available: every row shows $0.00 (untracked). Savings are stated per rail without dollar figures for rails 2–3.
- The specs change-request share (39/52) covers 21 agent PRs I enumerated from ledger rows and deep-dive trails, not every PR in the window.
- I did not check whether `kubectl` would help; the cluster-scope read was forbidden and wasn't needed for GitHub trails.
- The F6 model cohort has n = 5 and is directional only.

BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[{"mechanism":"specs-review-expanding-scope-exhausts-round-bound","surface":"specs reviewer rubric (ADR-155)","summary":"Specs reviewer files new blocking findings on rows unchanged since its first verdict (PR #3450: 6 CRs; PR #3337: 4 CRs); round bound exhausted and operator hand-finishes. Proposed: from round 2, findings on rows unchanged since the first verdict are Follow-ups unless they are regressions the PR introduced.","evidence":["https://github.com/teststuffstash/homelab/pull/3450","https://github.com/teststuffstash/homelab/issues/3449","https://github.com/teststuffstash/homelab/pull/3337","https://github.com/teststuffstash/homelab/pull/3324"],"related_work":[]},{"mechanism":"body-only-fix-classified-noop","surface":"agents/specs-reviewer-session.sh classify / README no-op invariant","summary":"A directive whose only correct action is a PR-body edit counts as a no-op (HEAD unmoved), escalates and idles ~62h (#3337 round 4). Extend #3429 with this case; no-op means HEAD unmoved and body unedited since the directive.","evidence":["https://github.com/teststuffstash/homelab/pull/3337","https://github.com/teststuffstash/oracle-fleet/pull/1082"],"related_work":["https://github.com/teststuffstash/homelab/issues/3429","https://github.com/teststuffstash/homelab/issues/2168"]},{"mechanism":"cross-goal-shared-registry-conflict-at-assembly","surface":"scripts/diff-ci.sh","summary":"Three concurrent island Goals each add a positional diff-ci.sh MAP row; conflicts surface at assembly PRs #3416/#3418 and the operator resolves them by hand (9 commits). Proposed: native blockedBy edges between sibling Goals' registry children at launch.","evidence":["https://github.com/teststuffstash/homelab/pull/3416","https://github.com/teststuffstash/homelab/pull/3418","https://github.com/teststuffstash/homelab/issues/3391"],"related_work":["https://github.com/teststuffstash/homelab/issues/3442"]},{"mechanism":"arbitrate-directive-split-across-issue-and-pr","surface":"agents/coordinator/README.md invariants (#1910 directive contract)","summary":"ARBITRATE directives posted alternately on issue #3396 and PR #3415; worker executed the stale surface's directive, giving no-op rounds r4, r7, r8. Proposed: once a PR is open, directives go on the PR only, with a pointer line on the issue.","evidence":["https://github.com/teststuffstash/homelab/issues/3396","https://github.com/teststuffstash/homelab/pull/3415"],"related_work":["https://github.com/teststuffstash/homelab/issues/1910"]},{"mechanism":"reviewer-re-reviews-parked-unfixable-pr","surface":"reviewer rubric","summary":"Reviewer re-files an identical version-window CHANGES_REQUESTED on every Renovate rebase, including 4 times after agent/blocked (oracle-fleet#1051); recurrence of r11 F2, not deployed. Proposed: skip agent/blocked PRs until a human removes the label.","evidence":["https://github.com/teststuffstash/oracle-fleet/pull/1051"],"related_work":[]},{"mechanism":"alt-model-first-touch-non-clean","surface":"agents/estimate_budget.py model routing","summary":"Non-sonnet first touches non-clean on 4 of 5 tasks (haiku 2/2, codex 2/2) vs sonnet 5/32; haiku now 4/4 across r11–r12. Proposed: route task/build first touch to the stack default until an alternate model has 10 or more ledger rows.","evidence":["https://github.com/teststuffstash/homelab/issues/3180","https://github.com/teststuffstash/homelab/issues/3191","https://github.com/teststuffstash/homelab/issues/3258","https://github.com/teststuffstash/homelab/issues/3395"],"related_work":[]}]}
```
END-RETRO-FINDINGS
