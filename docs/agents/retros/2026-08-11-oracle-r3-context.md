# oracle loop retro r3 — Claude Opus 5 (1M context)

## Summary (≤5 lines)
The loop's dominant cost is **infrastructure re-derived per-ride**, not model capability: 12 of 85 worker rounds died infra-class, and 8 of those are one `goose-32602-truncation` class whose cure (`GOOSE_MAX_TOKENS=16384`) has been known since 2026-07-25 but is wired into the *retro* ride path only, never the worker path.
Second cost is **reviewer non-convergence** — each fix round surfaces a fresh disjoint blocking set; oracle-fleet cured this on 2026-07-10 with a merge-forward maturity clause and circles never got one.
Wall-time is a red herring: the six worst rows are all successful merges whose wall ≈ PR open→merge idle (circles#41: 915s active inside a 44,483s wall, 99.5% matching its PR's lifetime).
Ledger blind spots named in the brief are confirmed, plus a fifth: **rank-1 is a mid-flight snapshot** (oracle-fleet#1 is live-state CLOSED/`agent/done` on PR #6, not blocked on PR #5).
One r1 process change merged and cleanly eliminated its failure class; the aggregate rounds/issue KPI cannot resolve the rest (n=6 pre-period).

## Findings (ranked, ≤6)

### F1 — `goose-32602-truncation` is a solved config class still killing rounds in every stack except the one that prompt-patched around it
**Evidence.** 10 harness-death rounds across 40 tasks. Strike trails: circles#19 r1, circles#22 r1 (×2), circles#32 r1 — all `error_class=goose-32602-truncation` on `deepseek/deepseek-v4-flash`, dated 2026-08-05…08-07; openrouter-operator#14/#15/#17/#18 — all `goose-32602-truncation` on `xiaomi/mimo-v2.5`, 2026-08-05…08-08. Cost of the two rounds whose stats were posted: $0.0353/1757s (circles#32 r1) and $0.0368/1462s (circles#19 r1), both with **no branch salvaged**. oracle-fleet has **zero** occurrences after 2026-07-09. The cure is recorded in `docs/agents/retros/2026-07-25-oracle-r1-RUN.md`: "GOOSE_MAX_TOKENS=16384 cures the -32602 truncation class (mimo proven)".

**Mechanism (falsifiable).** The 16384 ceiling is applied on two independent paths and the worker gets neither reliably. `agents/retro-session.sh:98` sets `GOOSE_MAX_TOKENS=16384` as a command prefix; `agents/agent-session.sh:716` — the worker's `goose run --recipe` invocation — does **not** set it at all (verified by grep over all 1636 lines: zero occurrences). The proxy floor (`argocd/resources/openrouter-proxy/openrouter-proxy.py:1881-1887`) rewrites the *upstream request*, but it is clamped by `floor = min(floor, pin["max_completion"])` and cannot govern goose's own client-side emit ceiling — which is exactly why mimo still truncated on 2026-07-25, sixteen days *after* the proxy floor shipped, and stopped only when the env var was added. oracle-fleet escaped by prompt-avoidance, not by fix: `.agents/fix.yaml`'s "WRITE FILES INCREMENTALLY … ≲50 lines per write/edit" hard rule. circles `.agents/build.yaml` has only an incremental-*push* rule (line 52-53), no incremental-*write* rule. Falsify by dumping env in a live circles worker pod: if `GOOSE_MAX_TOKENS=16384` is present, this is wrong.

**Process change.** Add the env prefix to the goose arm of `agents/agent-session.sh:716`, in the identical shape `agents/retro-session.sh:98` already uses: `goose) RUN_CMD="${CTX_PRELUDE}…; GOOSE_MAX_TOKENS=16384 goose run --recipe /tmp/fix-recipe.yaml --params issue=${ISSUE_N}"`.

**Expected saving.** 8 dead rounds in this ledger window ≈ 3.5h active compute + ~$0.30 direct, plus 6 round-2 restarts from zero artifact ("no resumable branch — nothing was committed" on 6 of 8).

### F2 — Fix rounds are spent on second- and third-generation reviewer findings, not on the issue
**Evidence.** oracle-fleet#1/PR#6: r1 `CHANGES_REQUESTED` (4 asks) → all 4 landed → **new** `CHANGES_REQUESTED` @01:04Z with two *new* correctness bugs → landed → **fresh** `CHANGES_REQUESTED` @02:20Z → round bound 3/3 → human merge-forward arbitration. Identical shape on the TS arm PR#5 (CHANGES_REQUESTED 09:36 → fixed → CHANGES_REQUESTED 10:05 "surfaced two deeper blocking bugs the new paths exposed"). circles#29's assembly PR#54 drew **four independent assembly reviews** and spawned six post-"goal met" fix children (#59,#60,#61,#68,#71,#73). `reviewer_rounds` is 0 on all of these (known blind spot; counted from trails).

**Mechanism.** The reviewer re-runs its full finding engine against the whole diff each round with no record of which findings were already adjudicated, so each landed fix enlarges the reviewed surface and yields a fresh blocking set — a random walk, not a convergence.

**Process change.** oracle-fleet already carries the cure and it measurably works: `.agents/review.md` §Maturity (PRE-PROD merge-forward, set 2026-07-10) restricts BLOCKING to secrets/blobs/CI-red/regression and routes everything else to `Follow-ups:` in an *approving* review — post-clause oracle-fleet reviews converge in one fix round (#177: CHANGES_REQUESTED → APPROVE; #57: CHANGES_REQUESTED → APPROVE). Copy that §Maturity block verbatim into circles `.agents/review-goal.md` (the assembly-PR rubric), scoped to assembly PRs.

**Expected saving.** ~2 rounds per assembly PR. oracle-fleet#1 spent 2 of its 3 logic rounds on findings that did not exist when the round budget was set.

### F3 — Infrastructure-class CI red is re-diagnosed from scratch on every PR, and only a human breaks the tie
**Evidence.** circles#19: `ci-red` triage fired four times (06:25, 06:49, 07:55, 09:01) across rounds 2–5 on PRs #50/#51. Two triages ruled "transient BuildKit/dind error, not a bug in this PR's code" and parked at `agent/blocked`; the operator re-ran and proved it reproducible (06:45), mis-diagnosed a port-forward race (07:57), self-corrected (08:35), and the true cause was a registry-cache entry serving **HTTP 200 / 0 bytes** (09:15). The same corrupt-blob class recurs as homelab#116 (08-07), homelab#240 and homelab#241 (08-11). Ledger for circles#19 reads `rounds:2, ci_sequence:[null,true]` — the whole four-hour loop is invisible.

**Mechanism.** `ci-red` triage has no cross-PR memory, so a fault affecting every PR is re-derived per PR from that PR's own log, and the correct conclusion ("not this PR's code") terminates in `agent/blocked` — a per-PR human ask — instead of one fleet-level signal.

**Process change.** Extend the `agent/error` clause in the coordinator brief's state-machine table (`agents/coordinator/README.md`, the row that already says *"Emit it yourself (label + one `AGENT_ERROR: <what>` comment) when YOU detect loop anomalies"*) with a third trigger: when `ci-red` triage has classified the same failing step as environmental on ≥2 distinct PRs within 24h, emit `AGENT_ERROR: infra-class CI red on N PRs` once rather than parking each PR at `agent/blocked`.

**Expected saving.** circles#19 alone: 4 ci-red dispatches + 3 human interventions + ~4h wall collapse to 1 dispatch + 1 human.

### F4 — Two of eight deep-dive tasks produced zero code because the scope was not executable by the dispatched worker class
**Evidence.** oracle-fleet#66: the entire deliverable is `.github/workflows/ci.yaml`, then banned by `.agents/fix.yaml`; worker exited `failed`, `ci_sequence:[false]`, no branch, no PR, `total_cost_usd 0.0` (haiku = UNTRACKED, not free). It correctly self-reported *"BLOCKED — not implementable as written"* — but there was no terminal for that, so it landed as `AGENT_STRIKE … error_class=unknown` and the coordinator had to **override the mechanical `c4c5-redispatch` clause by hand**. oracle-fleet#225: *"none of that is executable by a fix-class worker (no cluster/infra access, no live-API credentials, no oracle-iac checkout)"*; the worker rescoped itself, and its PR#256's `Fixes #225` then wrongly auto-closed the issue (reopened 19:03:31Z).

**Mechanism.** Dispatch sizes a model and a budget but never asks whether a worker of *this class*, under *this recipe's* forbidden-path list and *this pod's* credentials, can produce the deliverable — so feasibility is discovered inside a paid session, and the honest infeasible answer is indistinguishable from a crash.

**Process change.** Promote infeasibility to a first-class terminal in `.agents/fix.yaml`: alongside the existing `AGENT_ERROR:` breaker paragraph, add — if the deliverable requires a path in the Hard-rules ban list or a resource outside the pod (cluster, live API creds, a sibling-repo checkout), post one comment starting exactly `AGENT_INFEASIBLE: <the path/resource>` and END without pushing; the coordinator routes on that marker straight to `agent/blocked` instead of through `c4c5-redispatch`.

**Expected saving.** 2 of 8 deep-dive tasks × 1 wasted round + 1 hand-override each; converts a full session into a sub-minute exit.

### F5 — The budget cap is a kill switch sized by an estimator whose headroom is applied in the wrong place
**Evidence.** oracle-fleet#1 attempt 3: est $0.3024, cap $0.50, real spend **$0.5086** → `403 Key limit exceeded` at 3918s, entire run lost, zero artifact. Calibration errors where populated: sleep-tracking#71 **0.544** (3 rounds, blocked), circles#18 0.370, sleep-tracking#47 0.259, circles#32 0.224 — 4 of 9 populated rows exceed 0.2. The metric is degenerate where it looks best: oracle-fleet#135 shows err=0.000 against an actual of $0.00 (haiku, untracked).

**Mechanism.** In `agents/estimate_budget.py`, `BUFFER = 1.5` is applied to the point estimate *before* `pick_tier`, so a run landing just under a tier edge receives a cap barely above its true spend. Headroom exists at the estimate, not at the cap — and the cap is the circuit breaker. #1: $0.3024 × 1.5 = $0.4536 → tier `sm` ($0.50) → died at $0.5086, a 1.7% overshoot.

**Process change.** Raise the single documented tunable `BUFFER = 1.5  # headroom over the point estimate before choosing a tier` to `2.0` in `agents/estimate_budget.py`. This sits inside the module's own stated design intent ("the cap is the circuit breaker … over-sizing slightly beats throttling a legit fix"); #1 would have estimated $0.605 → tier `md` ($1.00) and completed.

**Expected saving.** One destroyed 65-minute run in the deep-dive set; 4 of 9 calibrated rows clear a tier edge under a 2.0 buffer. Over-sizing costs $0 unless actually spent.

### F6 — `wall_time_s` measures PR merge-gating, so the ledger's pain ranking points at successful merges
**Evidence.** The six worst wall rows are all `agent/done` with tiny active fractions: oracle-fleet#8 193,579s; oracle-fleet#194 80,648s / active 2,367s (2.9%); sleep-tracking#48 79,579/5,218 (6.6%); circles#18 45,801/5,203 (11%); circles#41 44,483/**915** (2.1%); oracle-fleet#201 32,425/1,647 (5.1%). Cross-checked against PR open→merge as the brief requires: circles#41's PR#44 open→merge = 44,688s vs ledger wall 44,483s (**99.5% overlap**); circles#18's PR#45 = 46,199s vs 45,801s. The wall *is* the PR's open→merge window, and it is idle — both are goal-#29 children merged into `goal/29-p0-complete` in dependency order.

**Mechanism.** Wall is stamped from dispatch to terminal, which for a merged PR includes the dependency-ordered merge queue — a scheduling property of the goal branch, not a property of the agent or the reviewer.

**Process change.** In the ledger emitter (FU-058 brief-v2(b), already open), rename the field to `pr_open_to_terminal_s` and drop it from the pain-rank key; `active_run_s` is already emitted on 34 of 40 rows and is the honest cost signal.

**Expected saving.** No compute saved — this prevents mis-targeting. Five of the ledger's ten worst-ranked rows are clean merges whose agent work took under 90 minutes.

## Proposed process changes

| change | artifact | expected saving | confidence |
|---|---|---|---|
| Prefix the worker's goose invocation with `GOOSE_MAX_TOKENS=16384`, exactly as the retro path does | `agents/agent-session.sh:716` (mirror `agents/retro-session.sh:98`) | 8 dead rounds / ~3.5h active / ~$0.30 in this window; 6 zero-artifact restarts | **High** — cure is proven ("mimo proven", r1-RUN.md) and the var is verifiably absent from all 1636 lines |
| Port the "WRITE FILES INCREMENTALLY … ≲50 lines per write/edit" hard rule into the circles builder recipe | circles `.agents/build.yaml` (from oracle-fleet `.agents/fix.yaml` Hard rules) | Defence-in-depth on the same 8 rounds; oracle-fleet's own truncation rate went to 0 under it | Med-High — correlational, oracle-fleet also got the proxy floor |
| Copy the §Maturity PRE-PROD merge-forward block to the circles assembly-PR rubric | circles `.agents/review-goal.md` (from oracle-fleet `.agents/review.md` §Maturity) | ~2 rounds per assembly PR; PR#54 drew 4 reviews + 6 post-"goal met" children | Med-High — worked on oracle-fleet (#177, #57 converge in 1 fix round) |
| Add a third `AGENT_ERROR` trigger: same failing step ruled environmental on ≥2 PRs in 24h | `agents/coordinator/README.md` state-machine table, `agent/error` row | circles#19: 4 ci-red dispatches + 3 human interventions → 1 + 1 | Med — depends on triage emitting a stable step identifier |
| Make infeasible scope a named terminal (`AGENT_INFEASIBLE:`) routed straight to `agent/blocked` | `.agents/fix.yaml`, beside the existing `AGENT_ERROR:` breaker | 2 of 8 deep-dive tasks; kills the hand-override of `c4c5-redispatch` | High — #66's worker already produces this judgment, it just has no terminal |
| `BUFFER = 1.5` → `2.0` before `pick_tier` | `agents/estimate_budget.py` | 1 destroyed 65-min run; 4 of 9 calibrated rows clear their tier edge | Med-High — mechanism exact on #1; wider effect inferred from calibration spread |

## Task granularity (per deep-dive task)

| # | task | verdict | evidence |
|---|---|---|---|
| 1 | oracle-fleet#1 | **chunked-right** (it was already one task) — the fix was policy, not granularity | 3 TS rounds + 5 infra deaths + 3 Python rounds. Zero cross-chunk friction: every burned round is either infra (token-expiry, 401 storm, budget-403, truncation) or a *new* reviewer finding on the same diff. Splitting the scaffold would have multiplied both. |
| 2 | sleep-tracking#71 | **unverifiable** | Repo not resolvable with this token. Ledger only: 3 rounds, `failed`/`failed`/`blocked-deliberate`, three different models, calibration_error 0.544 (worst in ledger). |
| 3 | circles#17 | **should-have-been-fan-out** — and the operator ran the controlled experiment | Frozen 2026-08-05T11:43 as *"the one-shot arm of a one-shot-vs-fan-out comparison"* against #29. One-shot: 1 builder, $0.2941 / 2060s, against a *15-page, 91-requirement* contract; reviewer found **three inline findings where "the diff directly contradicts a requirement the PR's own description lists as delivered"**; never merged. Fan-out (#29): 91/91 requirement coverage map, 5 core children + ~9 grandchildren, goal met 2026-08-08. Fan-out won on a contract this wide. |
| 4 | circles#19 | **chunked-right** | Single deliverable (the kind system gate). 100% of burned rounds are environment (corrupt registry blob); zero rework at integration. |
| 5 | circles#57 | **chunked-right, but it IS the integration-rework receipt** | #57 exists only because #29's assembly review found bake was never wired into the real Docker image — a seam between the bake children (#30/#31) and the page/image child (#32) that **no child owned**. Cost of that one missed seam: 4 rounds, $0.2524+$0.3544+$0.0291+$0.0476 = **$0.6835**. This is the measured price of fan-out, and it is still well under the one-shot arm's failure. |
| 6 | oracle-fleet#225 | **chunked-wrong — too coarse, mixed lanes** | Scope bundled in-repo code (ING-RT-FRESHNESS) with attended rebuild + oracle-iac#322 CronWorkflow + a live delta run. The worker split it itself and said so at 16:13Z; the loop then mis-closed the parent on `Fixes #225`. Should have shipped as two issues from the start. |
| 7 | sleep-tracking#43 | **unverifiable** | Repo inaccessible. Ledger only: 1 round, exit `no-artifact`, ci=true, closed, calibration_error 0.048. |
| 8 | oracle-fleet#66 | **right size, wrong lane** | One coherent deliverable; failed on feasibility, not decomposition (see F4). Splitting it would not have helped — every chunk hits the same banned path. |

## Wins to codify

**1. Commit the reviewer's finding RED before fixing it.** oracle-fleet#177 is the model run: issue open → merged in 70 minutes, 2 rounds, $0.0625+$0.017, one `CHANGES_REQUESTED` → one `APPROVED`. What made round 2 cost $0.017/355s is visible in the commit list — `test: pin empty/whitespace act -> act_not_found (RED: fold tier unguarded)` **then** `fix: guard title-fold tier against empty/whitespace act`. That is `.agents/fix.yaml`'s Spec-row-TDD step 2 applied to a *reviewer finding*, which the recipe currently only mandates for the issue's own behavior rows. Codify: extend step 2 with one sentence — "a reviewer's blocking finding is a row: commit it RED first, then fix." The reviewer's re-review then verifies against an executable pin rather than a claim.

**2. Arbitration should quote the exact edit, not the verdict.** circles#57 round 4 flipped `CHANGES_REQUESTED` → `APPROVED` on the first try at $0.0476/798s because the coordinator's arbitrate ruling named the literal change ("in `Dockerfile`, the bake stage currently does: `COPY pyproject.toml uv.lock ./` … reorder to copy `bake/`/`fixtures/` before `uv sync --frozen --no-dev`"). Contrast round 3 on the same PR: $0.0291/625s, clean stats, **no commit pushed** — an entire no-op round that only the FU-147 arbitrate unit caught. Codify into the coordinator's `arbitrate` play: a re-dispatch directive must carry the reviewer's suggested fix verbatim, and a round that posts stats without moving HEAD is a no-op round, not a consumed logic round.

**3. Already codified and worth naming as proven:** `.agents/review.md` §Maturity carries its own measurement in its text — *"three rounds on PR #6 found three disjoint bug sets and never converged; the scaffold was better than empty master the whole time."* That clause is the single highest-yield artifact in this ledger. F2 is just "install it in the other stack."

## Platform KPIs (ADR-103)

**(1) Bucket-A count — 19 distinct platform-logic failure events**, window 2026-08-04 → 2026-08-11, counting coordinator / review-reflex / prompt / scan defects filed as platform-repo issues (excluding pure infra — node, disk, kubelet, registry; excluding ADR-102/103 feature build-out; excluding docs-drift-only):

- *scan* (8): homelab#108, #120, #131, #134 (four `AgentCoordinateScanWedged` events), #155 (phantom `agent/in-progress` starves a stack), #198 (5 dispatches in 30m on byte-identical state), #226 (unblocked-and-unlabeled invisible to every clause), #228 (subject-reopen arrives pre-queued)
- *review reflex* (5): #114 (re-approves on every PR event, no idempotency guard), #122, #126, #128 (STEP-0 self-guard defects), #204 (second dispatch path bypasses `reviewer.enabled=false`)
- *coordinator* (3): #141 (arbitrate cannot mint the verdict it ruled for), #156 (rounds keyed on PR not issue — close-and-re-PR resets the breaker), #238 (fix-debounce re-queues a blocked issue every cycle)
- *prompt/launcher* (3): #165, #197 (prose-in-executing-code, "has now bitten four times"), #242 (128KiB `MAX_ARG_STRLEN` silent pre-pod cliff)

Adding the responder lane (#124, #125, #148, #149, #154, #239) takes it to **25**; I report 19 as the strict reading of the ADR-103 wording and flag the ambiguity rather than pick silently.

**(2) Jail $/day — NOT MEASURED.** `sum(increase(claude_code_cost_usage_USD_total{stack="jail"}[7d]))/7` is unrunnable from this jail: kubectl authenticates as `system:serviceaccount:oracle-fleet:agentstack-worker` and is namespace-scoped (`namespaces is forbidden … at the cluster scope`), and no Prometheus/Thanos endpoint is reachable. The metric is real and defined (`tofu/dashboards/agent-cost.json`), I simply cannot query it. Ledger-derived floor for the same window: **$0.504/day** of API-rail spend across 26 rides ($3.529 total) — but 5 of those 26 rows are $0.00 UNTRACKED (haiku/subscription: homelab#148/#149/#153/#155, circles#29), so this is a lower bound on a *different* quantity and must not be reported as the KPI.

**(3) Trend — unscoreable, and that is itself the finding.** homelab#237 (`RetroReportOverdue`, opened 2026-08-11T01:34) states no retro report has landed in >8 days, so there is no prior week's bucket-A count to compare against. The ADR-103 trigger condition ("sustained non-fall") cannot be evaluated until the retro pipeline produces two consecutive datapoints. Worse, #237's own remediation ride tripped the very class it was filed under: `AGENT_ERROR: dispatch loop — fix-debounce re-queues this issue every cycle *because* it is blocked`.

**(4) Proposed next gate — replay-pin the terminal-label exclusion in the debounce pending set.** Highest-recurrence unguarded class this week is *dispatch-on-terminal-state / re-fire on unchanged state* (#198, #226, #228, #155, #238 — five events). Three of those already got replay fixtures (`agents/replay/fixtures/state-fp`, `unblocked-unlabeled-surfaces`, `responder-reopen-*`), and the class stayed live via a path none of them cover: homelab#238, **open right now**, where `fix-debounce`'s pending set lacks `agent/blocked` + `agent/error` exclusions. The fixture directory listing confirms no case guards it. **Gate:** add `agents/replay/fixtures/fix-debounce-terminal-excluded/` — recorded world = one issue labelled `agent/blocked` and one labelled `agent/error`; expected actions = no dispatch, no re-queue, for both. `scripts/merge-path-lint.py`'s ADR-103 orphan gate ("every `guarded` transition must declare `replay:` or `unreplayed:`") already provides the ratchet, so the fixture converts a recurring defect into a CI-enforced invariant.

## Predecessor score

Two of retro r1's six proposed changes merged; **rounds/issue moved from 2.33 → 2.09 (−10%)**, but that aggregate is not attributable — see below.

**Merged & effective.** *"Carve out `.github/workflows/ci.yaml` for `track/chassis`"* → oracle-fleet#134, whose body opens `## Context (retro r1 F1 — the #66 deadlock class)`, closed 2026-07-26. Verified live in this checkout's `.agents/fix.yaml` Hard rules ("…amended 2026-07-26, oracle-fleet#134"). **Its class did not recur**: across all oracle-fleet issues created on/after 2026-07-26 touching ci/workflow/e2e (#152, #200, #222, #228, #240, #242, #243, #254), none blocked on a forbidden path. r1 predicted "unblocks #66's class; kills repeat block→human-META cycle (≥3 ticks + 2 humans on #47)" — that held.

**Merged, one leg of three.** *"Split wall into queue vs active; count reviewer rounds; price claude-tier by tokens"* → the wall-split leg landed and is structurally verifiable in this very ledger: **0 of 6** rows dated before 2026-07-26 carry `queue_wait_s`/`active_run_s`; **34 of 34** rows after do. The other two legs did **not**: `reviewer_rounds` is still 0 on all 40 rows (contradicted by CHANGES_REQUESTED trails on #1, #57, #177), and haiku/subscription still prices $0.00 on 8 rows.

**Unconfirmed (4).** Redispatch-gate on finalize payload; the scaffold-model routing gate; FU-021 401/403 hard-stop; review-scaffold follow-up routing. These target homelab-side artifacts and I found no landing commit for any of them.

**Honest read of the KPI.** Pre-period is n=6 (2.33 rounds/issue, 33% blocked) vs post n=34 (2.09, 32% blocked) — the pre-period is far too small to carry a −10% claim, and the post-period simultaneously acquired a failure source the pre-period lacked (12 infra-death rounds, **all** in circles/openrouter-operator/sleep-tracking; oracle-fleet post-period has zero). The one change with a clean causal chain eliminated its class outright; the aggregate cannot resolve the others.

## Evidence confidence

- **Two of eight deep-dive tasks have no trail.** `teststuffstash/sleep-tracking` is not resolvable with this token (`Could not resolve to a Repository`), so ranks 2 (#71) and 7 (#43) are ledger-only. #71 carries the worst calibration error in the set (0.544) and I could not test whether it belongs to the F4 infeasible-scope class, which its `failed`/`failed`/`blocked-deliberate` signature is consistent with.
- **Jail $/day is unmeasured**, not estimated — cluster RBAC blocks the query (details in KPI 2). I did not substitute the ledger figure for it.
- **A fifth ledger blind spot, beyond the four the brief names: the rank-1 row is a mid-flight snapshot.** The ledger has oracle-fleet#1 as `agent/blocked` / `issue_state: OPEN` / `pr_url: …/pull/5`; live state is **CLOSED, `agent/done`, 2026-07-10T04:58:51Z**, and the real PR was **#6** (#5 was closed unmerged in the TS→Python language reversal). Its `ts` (2026-07-09T12:36:43Z) falls mid-task. The whole pain ranking may be ordered on non-terminal snapshots.
- **Goal-container tasks are invisible to the ledger.** circles#29 is emitted as all-zeros (`rounds: 0`, `models: []`, `total_cost_usd: 0`) for a task whose trail shows ~20 coordinator goal-review dispatches, 9 rounds on assembly PR#54, and $2.78 of ledger-visible child spend across 27 child rounds. Any per-issue cost analysis that includes goal issues is wrong by construction.
- **`retry_storms` confirmed uninstrumented as briefed**: 1 event in 40 rows, while trails show model-level loops that never increment it (openrouter-operator#14 r1, `error_class=repetition_loop`, "eight consecutive ~max_tokens completions in ~30 minutes", no branch, no PR).
- **F1's mechanism is verified as far as static evidence permits** (env var absent from `agent-session.sh`, present in `retro-session.sh:98`, proxy floor clamped by `min(floor, pin["max_completion"])`, and the cure post-dating the proxy fix by 16 days) — but I could not exec into a live worker pod to confirm the pod's actual environment, which is the decisive test.
- **F2's saving is directional.** oracle-fleet's convergence improved after §Maturity landed, but the maturity clause, the model change, and the recipe hardening all landed in the same window; I cannot isolate the clause's individual contribution.
- **F3's `≥2 PRs in 24h` threshold is my proposal, not a measured optimum** — the evidence supports "cross-PR memory is missing," not that 2 is the right number.
