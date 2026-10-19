# platform loop retro r9 — Opus 5.5 (claude-opus-5-5)

## Coverage (window, bundle identity, completeness, late corrections)
- **Window:** 2026-10-12T00:00Z → 2026-10-19T00:00Z (exclusive). Collected until 2026-10-19T04:30:11Z, prepared 05:00:12Z.
- **Bundle:** run `r9`, series `platform`, `bundle_id 539cfaf5…c916`, `source_revision ce2cf12a`, `storage_key platform/runs/20261019T000000Z`, schema v1.
- **Population (whole window, 12 repos):**
  - 505 tasks, 6,644 events, 269 failure events, 0 infra-failure events, 91 superseded cancellations.
  - 55 `agent-dispatch` events and 47 stat records. Measured worker cost is $2.98, but only 20 of the 47 stat records have a cost.
- **Sample:** 20 of 505 tasks selected (cap 40). Ranks 1–8 are the deep-dive set.
- **Ledger:** `rows_emitted` is 29, but only 21 rows are serialized in the bundle (byte cap). The population counters below cover all 29 / 38 round entries.
  - Exit statuses: clean 27, ci-failed 7, harness-death 1, input-unreadable 1, blocked-deliberate 1, no-op 1.
  - First-touch non-clean rate: sonnet 4/12, deepseek-v4.1-flash:exacto 3/15, opus 0/1.
- **Ledger blind spots (stated once):**
  - `reviewer_rounds` is always 0, so review rounds are counted from trails.
  - `wall_time_s` is not split into active and idle time, so I cross-checked it against PR open→merge times.
  - `retry_storms` counts harness-level retries only.
  - A `total_cost_usd` of 0.00 on subscription rows means untracked, not free.
- **Late corrections:** 1,168 late arrivals; 20 are serialized. All 20 are dated 2026-08-06…08 (oracle-fleet#209 ×16, circles#33 ×4) and were observed 10-16/10-18. They are CI/label events that belong to their August periods, and nothing in them changes a prior finding. Excluded from this window's totals.
- **Context:** `previous_findings` is empty (`previous_findings_total` = 17), so predecessor strings come from the r8 opus report file.

## Summary (≤5 lines)
1. **One upstream release (CPython 3.15) took over the deep-dive set.** It accounts for 5 of 8 deep-dives, 6 Renovate PRs across 4 repos, three contradictory rulings, ~6 operator touches and ~16 bot rides. The final rule was "park until nixpkgs ships a stable 3.15", and nothing in the loop encodes it.
2. **circles#124 is a live phantom.** Three fix rounds were dispatched with no pod, no push and no strike. It has carried `agent/in-progress` for 27.5 h in-window, and the C4/C5 phantom reaper can't see it because the unit *is* the open PR.
3. **Two open fixes block each other.** The inherited-master-red fix (#2588) is itself latched `agent/error` by a GitHub-pool rate-limit strike, and the fix for that (#2601) is also open: 3+ days of stall at window end.
4. **Bucket-A is 8, down from 14** (13 → 13 → 14 → 8), the first fall in four weeks. Only 4 of the 8 were first observed this week, and the r8 goal-lifecycle gate is still unbuilt while its class recurred twice.
5. **The r8 changes that shipped look effective:**
   - r8 F1 (pin-vacuity check): 0 of 24 CHANGES_REQUESTED verdicts cite vacuity, against 17/44 in r8.
   - r8 F3 (cap classifier): worker-stop-report fell from 8 to 1.

## Findings (ranked, ≤6)

### F1 — The Python version set has no fleet-level hold rule, so every repo's Renovate PR re-derives "nixpkgs only has an rc" and ends with a human ruling
**Evidence (in-window, dated):**
- **openrouter-operator#90:** merged 10-13 05:56Z with devbox pinned to **3.15.0rc1**, after a seat codeowner read. This contradicts the later rulings below.
- **oracle-fleet#759:**
  - 10-13 00:22Z: coordinator parks it as "not a one-line adaptation".
  - 10-13 00:31Z and 13:27Z: two rebase repairs after the park.
  - 10-15 18:28Z: the seat closes it and files #863.
- **oracle-fleet#863 → PR #869:** merged 10-15 with one sonnet round, first approval.
- **oracle-fleet#879** (same branch): on 10-16 10:46Z the fixer *reverted* the bump to a no-op because nix has only 3.15.0rc2. It merged as a no-op.
- **oracle-fleet#883:** **Renovate re-proposed the same update 5 h later** (10-16 16:04Z).
  - Seat hold at 19:47Z, coordinator unarmed-major ride at 20:40Z.
  - Operator ruling on 10-18 13:04Z: "parked until nixpkgs ships a stable Python 3.15".
- **homelab#2610:**
  - 4× reviewer CHANGES_REQUESTED (10-17 14:53Z → 10-18 10:18Z; 3 of them on content-identical Renovate rebases).
  - 2 coordinator rulings (10-17 15:01Z, 10-18 19:33Z).
  - Seat park plus the class-fix PR #2720 on 10-18 19:28Z.
- **circles#124:**
  - 3× reviewer CHANGES_REQUESTED.
  - 3 coordinator dispatches whose ARBITRATE directive says "if nixpkgs lacks 3.15, use the newest available 3.x", which contradicts the fleet ruling.
  - Still open (F2).
- **Totals:** about 6 operator touches across 5 distinct days; about 7 reviewer rides; about 9 coordinator rides; 2 sonnet fixer rides.

**Mechanism:** Renovate's proposal is gated only per repo. The set assertions (#869, #2720) catch *disagreement* between members. They don't encode *"the devbox member cannot move to a stable release yet"*, which is a fleet-wide fact that only a human currently rules on. So every repo goes red or gets CHANGES_REQUESTED, the lane rides the PR, and a human rules again. A no-op merge (#879) also clears Renovate's ignore, so the same proposal comes back (#883).

**Falsifiable:** with a dashboard-approval hold in place, no new `python` minor PR appears in any repo until the box is ticked.

**Change:** add one `packageRules` entry in **`renovate-global.json`** (the org preset the README names as the `major` marker source):
- match `python` docker tags (and `uv:pythonX.Y` images) on `minor`;
- set `dependencyDashboardApproval: true`;
- add a comment recording the 10-18 operator ruling ("tick when nixpkgs carries the non-rc").

The proposal then waits on the dashboard instead of riding the lanes in N repos. The existing set assertions still guard the moment it is ticked.

**Expected saving:**
- **Rail 1:** about 5 of the 6 operator touches per CPython minor collapse into one dashboard tick. Assuming ~2 were out of sitting (E ≈ €20–30) and ~3 in-sitting (€3–8), that's **≈ €50–85 per upstream minor**. The same shape covers future set members (node, go).
- **Rail 3:** about 16 reviewer/coordinator rides, i.e. cents amortized.

**Confidence:** high on the evidence; medium on the size of the saving (whether touches were in or out of sitting is inferred from timestamps).

### F2 — A PR-keyed fix round that never launches is invisible: no strike, no reaper, and `agent/in-progress` sticks
**Evidence:**
- circles#124 dispatches: round 1 at 10-17 10:29:33Z, round 2 at 15:32:16Z, round 3 at 20:31:36Z. The coordinator's own lines say "rounds 1–2 left no pod, push or strike".
- The head is still Renovate's `9dae387`. Its only check-runs are ci/e2e/evidence/approve, with no `agent-ride`.
- The label is still `agent/in-progress`. Bundle `standing_stall_seconds` = **98,904** (27.5 h in-window), and it was ongoing at observation time.
- Contrast: oracle-fleet#879, same lane, launched and finished in one ride (10-16 10:44 → 10:46Z).

**Mechanism:** the C4/C5 phantom predicate removes `agent/in-progress` only when there is "no live pod, **no open PR**, no merged PR". On a PR-keyed unit (a Renovate branch under the #2521 lane) the open PR is the unit itself, so that leg is never true. The launch failed before any strike could be written, so ADR-127's strike→swap→`agent/error` path never starts.

**Falsifiable:** a pod or an `agent-ride` check-run for `agent-circles-pr-124-r*` exists, or the reaper does fire on an issue-keyed twin.

**Change:** add a no-launch leg to the `agent/in-progress` phantom rule in **`agents/coordinator-scan.sh`** (the C4/C5 clause, README state-machine row):
- **Trigger:** for a PR-keyed unit, a `picking this up (round N)` dispatch older than `C4C5_PERSIST_S` with no `agent-ride` check-run, stats or `AGENT_STRIKE:` newer than it.
- **Action:** count it as a strike (`error_class=launch-failed`). The README's identical-pair rule then routes a second occurrence to `agent/error` instead of a third silent dispatch.

**Expected saving:**
- **Rail 1:** turns a silent stall, which an operator eventually finds out of sitting (≈ €20–30 E), into one routed `agent/error` item handled in-sitting (€3–8).
- **Wall:** 27.5 h+ of stall on this one item.
- **Rail 3:** 1–2 coordinator rides.

**Confidence:** high that it is a phantom with no reaper (trail + README predicate). Low on why the pod never launched (TOOL_GAP below).

### F3 — The rate-limit strike latches human-first, and it has latched the inherited-master-red fix
**Evidence:**
- Inherited red, two instances this week:
  - homelab PR #2582 sat about 19 h red and BEHIND (opened 10-14 22:12Z) until the seat ran `update-branch` by hand. Master's red came from the docs-graph-lint break of #2575/#2576.
  - homelab#2660 (agent-gateway deploy bump) was cut from a red master on 10-17 08:33Z. It never got a second approval and the seat closed it at 12:31Z.
- The fix for that class, **#2588**, rode on 10-15 at 20:14Z and 20:20Z. Both rides ended `input-unreadable / rate-limit`, an identical `(model, error_class)` pair, so it was latched `agent/error` at 20:29Z.
- The ledger shows the same class on **homelab#2562** round 1, about 23 h earlier. The ruling filed **#2601** (still open). #2588 is still open and latched at window end: about 3.1 days.

**Mechanism:** `rate-limit` is the drained-GitHub-pool class, which a wait fixes and a model swap can't. The README's "second strike with the identical pair → `agent/error` STRIKE channel" invariant treats it like a model fault. The fleet-fault un-latch only fires when the cited cause issue (#2601) closes, so the fix for one fleet fault is held by another.

**Change:** none new. This is #2601's substance, linked rather than refiled. Make it explicit in the **coordinator README** Invariants clause ("a second strike with the identical `(model, error_class)` pair… routes to `agent/error`"): exclude `rate-limit` as a deferral. Then sequence #2601 before re-queueing #2588.

**Expected saving:**
- **Rail 1:** 2 in-sitting seat touches per week on inherited red (€6–16), plus avoiding one fleet-fault latch per pool drain (≈ one E, €20–30).
- **Wall:** about 23 h of PR stall this week.

**Confidence:** high (trail + ledger).

### F4 — Parked Renovate PRs keep spending rebases, CI and reviewer rides after the human gate is set
**Evidence (all after the park ruling):**
- **allure-behavior-snippets#11:** parked "blocked-on: human" 10-13 13:34Z. Then 2 rebase repairs (10-16 03:00Z, 10:35Z), each followed by a known-red `build` (10:36Z, 16:04Z).
- **oracle-fleet#759:** 2 rebase repairs (10-13 00:31Z, 13:27Z) after the 00:22Z park.
- **homelab#2610:** 3 reviewer CHANGES_REQUESTED (10-17 20:05Z, 10-18 02:38Z, 10:18Z) after the 15:01Z park. The reviewer itself notes each head is "a Renovate rebase; same content".

**Mechanism:** two writers don't read `agent/blocked`:
- The DIRTY-Renovate rebase repair (the homelab#1977 class).
- The review reflex. Unlike the unarmed-major `state-fp` (#2100), it doesn't key on diff content.

**Change:** in **`agents/coordinator-scan.sh`**, have the DIRTY-Renovate rebase repair skip PRs carrying `agent/blocked`. Optionally, reuse the #2100 content-hash to suppress re-review of a content-identical rebase.

**Expected saving:** rails 2–3 only. About 7 rides plus about 4 CI runs per week, i.e. cents plus CI minutes. **No rail-1 saving is claimed.**

**Confidence:** high on evidence, low on value.

## Proposed process changes (table: change | artifact | expected saving | confidence)
| change | artifact | expected saving | confidence |
|---|---|---|---|
| Hold `python` (and `uv:python*`) minor docker-tag bumps behind `dependencyDashboardApproval`, with a comment recording the 10-18 "tick when nixpkgs is non-rc" ruling | `renovate-global.json` packageRules | Rail 1: ≈ €50–85 per upstream minor (5 of 6 operator touches); rail 3: ~16 rides (cents) | high / medium |
| PR-keyed unit: a dispatch older than `C4C5_PERSIST_S` with no `agent-ride`/stats/strike becomes a `launch-failed` strike (second one → `agent/error`) | `agents/coordinator-scan.sh` C4/C5 phantom `agent/in-progress` rule | Rail 1: one out-of-sitting E (€20–30) becomes an in-sitting item (€3–8); 27.5 h+ stall; 1–2 rides | high (phantom) / low (root cause) |
| Exclude `rate-limit` (drained pool) from the identical-pair→`agent/error` invariant (= #2601); land it before re-queueing #2588 | coordinator README Invariants clause (+ #2601) | Rail 1: €6–16/wk inherited-red touches + ≈ one E per pool drain; ~23 h PR stall/wk | high |
| The DIRTY-Renovate rebase repair skips `agent/blocked` PRs | `agents/coordinator-scan.sh` (homelab#1977 repair) | Rails 2–3 only: ~7 rides + ~4 CI runs/wk | high (evidence) / low (value) |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)
1. **oracle-fleet#883: should-have-been-one** (a single fleet decision, not a per-repo PR). It is the third PR for the same update (#759 → #879 → #883), spawned by #879's no-op merge. Zero worker rounds; the cost is all in rulings (F1).
2. **oracle-fleet#759: should-have-been-one** (same). The coordinator correctly ruled on 10-13 that it was "not a one-line adaptation". It took 2.7 more days and 2 rebase repairs to close.
3. **oracle-fleet#863: chunked right.** It is a single-assertion chunk at xs: one sonnet round, PR #869 opened 20:16Z, approved at 20:41Z. The only friction was cross-chunk: the closeout depended on a Renovate re-proposal (closed 10-16 after #879).
4. **oracle-fleet#820: chunked right.**
   - It was re-scoped 10-08 to fetchers only, with #821 split off.
   - Round 2 was in-chunk work (boto3 session concurrency, from review).
   - The A/B failed on Garage connection placement (control datum `ht8p9`: one reader on the slow zone was 3.5× slower), not on chunk integration.
   - Ledger ci-red ×2 (sonnet).
5. **allure-behavior-snippets#11: should-have-been-one** (the Renovate group with `tests/Dockerfile` playwright image). The coordinator diagnosed a one-line lockstep fix on 10-13. The repo has no fixer lane, so it is parked, with 201,339 s of stall.
6. **homelab#2610: should-have-been-one** with F1's fleet decision. A worker round was correctly ruled infeasible (`devbox.json` is NEVER TOUCH in the homelab fix recipe).
7. **homelab#2660: n/a, not a chunked task.** It is a deploy bump cut from a red master (F3 class), and a no-op in content.
8. **circles#124: should-have-been-one** (F1), plus a launch defect (F2). There were 3 dispatches and 0 worker rounds, so no rework happened.

## Wins to codify (or "none observed")
- **The version-set assertion** (oracle-fleet#863 → #869: xs, 1 sonnet round, first approval, ~25 min PR open→approve) was ported unchanged to homelab gateway #2720 within 3 days.
  - **Codify:** put "a version-set assertion test" in the fix recipe's chassis checklist for every repo with a pinned interpreter. circles has none, and its reviewer re-derived the set 3 times.
- **Good-run contrast, homelab#2178 → PR #2570:** 1 deepseek round, $0.34, worker wall 127 s, bot APPROVED 8 min after open.
  - The ~21 h to merge was the codeowner gate (human APPROVED 10-15 17:29Z), not loop latency.
  - Reusable: a fully specified `Touches:` plus a ruling-shaped body produces a one-round fix.

## Platform KPIs (bucket-A count · trend · proposed next gate)
**Bucket-A: 8** (r7/r8 rule: distinct platform-logic defect issues against homelab in coordinator, review-reflex, prompt-brief, scan and launcher/worker-harness classes, plus one unfiled live defect).

| class | issues |
|---|---|
| scan | #2562 (C4/C5 bare mention), #2565 (goal-checkpoint trigger (c)), #2589 (epic dispositions re-fire trigger (c)) |
| launcher / worker-harness | #2563 (responder retry holds semaphore), #2571 (deep-dig sibling), #2601 (rate-limit burns ride and parks) |
| merge-path / updater | #2588 (inherited master red) |
| coordinator / launcher (unfiled) | circles#124 phantom PR-keyed dispatch (F2) |

- **Excluded:**
  - CI-lint / gates: #2561, #2572, #2576, #2577, #2600, #2605.
  - Carrier: #2566.
  - Other: #2512, #2555, #2564, #2567, #2650, #2684, #2685, #2718.
- **Trend: 13 → 13 → 14 → 8.** This is the first fall, with caveats:
  - Only 4 were *first observed* this week (#2588, #2589, #2601, circles#124). #2562, #2563, #2565 and #2571 are an FU-ruling batch filed 10-14 20:04–20:50Z for earlier-observed defects.
  - Dispatch volume was lower (55 dispatch events, no goal day).
  - **The ADR-103 AgentStack-CR trigger is not met this week**, but one week doesn't make a trend. Re-score at r10.
- **Proposed next gate:** a Renovate/PR-keyed state axis in the clause-coverage replay (`agents/replay/fixtures/clause-coverage/`, PR #2329). It would enumerate armed `deps-review` PR × {red-own, red-inherited (master was red at run start), CHANGES_REQUESTED} × {none, `agent/in-progress` with no ride, `agent/blocked`} and assert exactly one owning clause or hold per state.
  - It is the highest-recurrence class this week that is still unguarded and still live: #2588, circles#124, F4's parked-PR churn, and #2605 (gate-side).
  - It is a narrowing of r8's still-undeployed PR-state-axis gate. That gate's goal-lifecycle half recurred too (#2565, #2589).

## Predecessor score (deployment evidence and opportunities, or "insufficient evidence")
- **r8 F1 (pin-vacuity check as `::error` on stacked bases): deployed and effective in direction.**
  - `ci.yaml` L423–491 now reverts the PR's own non-fixture changes to merge-base and errors when nothing reds.
  - Opportunities: 24 reviewer CHANGES_REQUESTED fleet-wide in-window, 0 citing vacuity (r8: 17/44).
  - Caveat: I didn't count goal/** base PRs this week, so the opportunity set may be small.
- **r8 F3 (cap classifier): deployed (`agent-session.sh` L3427–3450) and effective.**
  - `worker-stop-report` fell from 8 to 1 (oracle-fleet#835, a genuine deliberate stop that resumed cleanly).
  - homelab#2412's turn-cap was classified `harness-death/turn-cap` and retried clean in round 2.
- **r8 F4 (estimator context): deployed as a constant raise, 20k → 50k** (`DEFAULT_CONTEXT_TOKENS = 50_000`), not footprint-derived.
  - Opportunities: 0 `budget-403` in 38 round entries; measured costs $0.04–$0.68, all under cap.
  - Insufficient evidence for credit: few scan-footprint children ran this week.
- **r8 F2 (goal-budget subscription charge), r8 F5 (arbitrate deferral re-arm): insufficient evidence.** No deployment found and no opportunity observed (no `Round deferred (capacity)` in the deep-dive trails).
- **r8 next gate (clause-coverage PR-state axis): not deployed.** No commits to `agents/replay/fixtures/clause-coverage` since 10-10, and its class recurred (#2565, #2589).
- **r7 F5 (egress-denied class): deployed** via agent-runtime#165, merged 10-14 18:28Z. Insufficient evidence: `infra_failure_events` is 0.
  - Side note: #165 stayed parked `agent/blocked` from 10-09 to 10-14 17:45Z although its blocker #166 closed 10-09 19:35Z. That's 65.8 h in-window, released only by a seat board sweep. It's an n=1 not-released-on-blocker-close case, noted but not a finding.
- **#2521 deps-review lane (merged 10-12, context): 1 of 3 opportunities worked.**
  - oracle-fleet#879: ride ran.
  - homelab#2610: correctly ruled infeasible by recipe.
  - circles#124: never launched (F2).

## Evidence confidence (what you could NOT verify and why)
TOOL_GAP: kubectl get pods -n circles-agents — needed to see whether circles#124's three rounds ever created a pod (the `agentstack-worker` SA is forbidden to list pods there)
- **F2's root cause (why no pod launched)** is unverified for that reason. Worker transcripts (`s3://agent-transcripts/`) weren't reachable either.
- **Ledger:** only 21 of 29 rows are serialized in the bundle. 27 of 47 stat records have no cost, so rail-2 numbers are partial.
- **Responder ledger:** not reachable. Bucket-A comes from homelab issues plus one trail-observed defect, and the class assignments are my reading of titles and bodies.
- **Rail-1 sizing:** whether a touch was in or out of sitting is inferred from timestamp clustering, not from operator logs.
- **Repo access:** all 12 stack repos were readable with the fleet read token (`RETRO_GH_TOKEN` present).

BEGIN-RETRO-FINDINGS
```retro-findings-json
{"schema_version":1,"findings":[{"mechanism":"python-version-set-no-fleet-hold-until-nixpkgs-stable","surface":"renovate-global.json packageRules (python docker-tag minor)","summary":"CPython 3.15 produced 6 Renovate PRs across 4 repos with 3 contradictory rulings (rc1 merged in openrouter-operator, parked in oracle-fleet/homelab, 'newest 3.x' directive in circles), ~6 operator touches and ~16 bot rides, and a no-op merge (#879) re-spawned the same proposal (#883) 5 h later; hold python minor bumps behind dependencyDashboardApproval with the 10-18 'tick when nixpkgs is non-rc' ruling recorded","evidence":["https://github.com/teststuffstash/oracle-fleet/pull/759","https://github.com/teststuffstash/oracle-fleet/pull/879","https://github.com/teststuffstash/oracle-fleet/pull/883","https://github.com/teststuffstash/homelab/pull/2610","https://github.com/teststuffstash/circles/pull/124","https://github.com/teststuffstash/openrouter-operator/pull/90"],"related_work":["https://github.com/teststuffstash/oracle-fleet/issues/863","https://github.com/teststuffstash/oracle-fleet/pull/869","https://github.com/teststuffstash/homelab/pull/2720","https://github.com/teststuffstash/homelab/pull/2521"]},{"mechanism":"pr-keyed-dispatch-no-launch-invisible-to-phantom-reaper","surface":"agents/coordinator-scan.sh C4/C5 phantom agent/in-progress rule","summary":"circles#124 got three PR-keyed fix-round dispatches (10-17) with no pod, push, strike or agent-ride check-run, and has held agent/in-progress for 27.5 h in-window because the phantom predicate's 'no open PR' leg is never true when the unit is the PR; treat a dispatch with no ride/stats/strike past C4C5_PERSIST_S as a launch-failed strike so the identical-pair rule routes it to agent/error","evidence":["https://github.com/teststuffstash/circles/pull/124"],"related_work":["https://github.com/teststuffstash/homelab/pull/2521"]},{"mechanism":"rate-limit-strike-latches-agent-error","surface":"coordinator README Invariants identical-pair strike rule / agent-finalize rate-limit class","summary":"A drained GitHub pool (rate-limit, input-unreadable) on homelab#2562 and twice on #2588 within 24 h tripped the identical-pair rule and latched #2588 (the inherited-master-red fix) agent/error for 3+ days while #2582 sat 19 h and #2660 was closed by hand on inherited red; exempt rate-limit from the identical-pair latch as a deferral (#2601) and land it before re-queueing #2588","evidence":["https://github.com/teststuffstash/homelab/issues/2588","https://github.com/teststuffstash/homelab/issues/2601","https://github.com/teststuffstash/homelab/pull/2582","https://github.com/teststuffstash/homelab/pull/2660","https://github.com/teststuffstash/homelab/issues/2562"],"related_work":["https://github.com/teststuffstash/homelab/issues/2601","https://github.com/teststuffstash/homelab/issues/2588"]},{"mechanism":"parked-renovate-pr-keeps-rebase-and-review-churn","surface":"agents/coordinator-scan.sh DIRTY-Renovate rebase repair (homelab#1977 class) / review reflex","summary":"After agent/blocked parks, allure-behavior-snippets#11 and oracle-fleet#759 each took 2 more rebase repairs (with known-red builds) and homelab#2610 took 3 more reviewer CHANGES_REQUESTED on content-identical rebases; skip the rebase repair on agent/blocked PRs (rails 2-3 only)","evidence":["https://github.com/teststuffstash/allure-behavior-snippets/pull/11","https://github.com/teststuffstash/oracle-fleet/pull/759","https://github.com/teststuffstash/homelab/pull/2610"],"related_work":[]}]}
```
END-RETRO-FINDINGS
