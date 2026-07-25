# Oracle loop retro r1 — goose
## Summary (≤5 lines)
- 32 tasks, 40 rounds, 0 reviewer rounds logged, $0.57 total cost (4 deepseek tasks), 2 blocked (recipe-policy), 28 done
- Deepseek burns rounds on tool-output truncation (15k-char monolithic writes → EOF); haiku burns wall-time on infra (token-expiry, nixpkgs pulls, ConnectionRefused)
- Reviewer rounds invisible in ledger (always 0) despite active PR reviews; calibration missing for 90% of tasks
- Recipe `.agents/fix.yaml` blanket bans contradict lane charters, causing human-blocked rounds (#47, #66)
- Exit telemetry inconsistent: 3 tasks report "failed" but terminal "agent/done"; 8/38 CI results null
- Wall-time outlier #8: 53.8h for 2 green rounds (queue/coord wait, not model time)

## Findings (ranked, ≤6)

### 1. Deepseek truncation burns 2 full rounds on single-file writes
**Evidence**: #1 (round 1: 15,267-char write → `-32602 EOF`; round 3: 14,781-char write → same) and #8 (deepseek model). Ledger: both deepseek tasks show wall_time_s > 0 and total_cost_usd > 0 but terminal agent/blocked or multi-round. Issue trails confirm: "monolithic write gets truncated at model's output limit" (#1), max_tokens=4096 default in goose→OpenRouter path (meta-coordinator note).  
**Mechanism**: Recipe instruction "write incrementally, ≲50 lines" is advisory only — the LLM emits a single large tool call; goose's default max_tokens=4096 truncates it mid-call, producing unparseable EOF. No harness-level guard prevents this.  
**Process change**: In `.agents/fix.yaml`, add a `pre_tool_hook` (or `check:` clause) that rejects any `write`/`edit` tool call whose `after` content exceeds 2000 chars, forcing the model to chunk. This is a hard harness gate, not an instruction.  
**Expected saving**: 2 rounds × $0.12 avg deepseek cost = **$0.24 + ~3h wall-time** per deepseek scaffold task; eliminates the truncation→auth-storm cascade.

### 2. Reviewer rounds invisible in ledger (reviewer_rounds=0 for all 32 tasks)
**Evidence**: Ledger field `reviewer_rounds` is 0 for every task. But issue trails show active review cycles: #1 had 2 CHANGES_REQUESTED rounds (round 2 and 3 reviewer feedback), #8 had round 2 fix for unflagged specs/ edit, #43/#42/#47/#52 all show reviewer comments. The coordinator dispatches reviewer bot on PR green, but its rounds aren't counted in the ledger.  
**Mechanism**: The ledger schema records `rounds` (worker fix rounds) and `reviewer_rounds` separately, but the coordinator's reconcile logic only increments `rounds` on worker dispatch. Reviewer turns are a parallel track that never writes back to the ledger row.  
**Process change**: In `coordinator-scan.sh` (or the reconcile function that writes the ledger), add a `reviewer_rounds` increment when the reviewer bot posts a verdict (CHANGES_REQUESTED or APPROVE) on the task's PR. One line: `jq '.reviewer_rounds += 1'`.  
**Expected saving**: Enables measuring review latency and correlation with fix-round count; currently blind. No direct round saving, but **unblocks future optimization** of the review loop (e.g., catch "reviewer never dispatched" which happened on #1 round 1).

### 3. Calibration data missing for 90% of tasks (ranks 1–29)
**Evidence**: `budget_tier`, `budget_cap_usd`, `calibration_error` are all `null` for ranks 1–29 (29/32 tasks). Only ranks 30–32 (issues #108, #107, #121) have `budget_tier: "md"`, `budget_cap_usd: 1.0`, `calibration_error: 0.0`. Deepseek tasks (#1, #3, #6) show actual costs $0.125–0.248 but no budget estimates to calibrate against.  
**Mechanism**: The budget estimator / tier assignment was added after the first 29 tasks ran (or only activates for ingest/server tracks with `agent-budget/md` label). The ledger writer doesn't backfill or default.  
**Process change**: In the budget estimator (dispatch-time), always emit a tier+cap estimate even for "free" models — e.g., `budget_tier: "xs"`, `budget_cap_usd: 0.25`, `est_usd: <model-specific>`. Write these to the ledger row at dispatch. For haiku (free), set `est_usd: 0.0` explicitly so `calibration_error = actual/est` is computable (0/0 → 0 by convention).  
**Expected saving**: Enables cost-tracking dashboards and model-selection optimization. Currently **$0.57 total cost is untraceable to estimates** — cannot answer "are we over/under budget?"

### 4. Recipe blanket bans contradict lane charters, causing human-blocked rounds
**Evidence**: #47 (rank 2) blocked 3× by coordinator before human amended `.agents/fix.yaml` (commit 3f3df8b) to permit `chart/**` for `track/deploy`. #66 (rank 18) still blocked: `.github/workflows/ci.yaml` is `track/chassis`-owned per `specs/TRACKS.md` but recipe forbids `.github/` with no carve-out. Worker #66 r1 stopped and reported rather than violate recipe. Ledger: #47 took 3 rounds + 4396s wall-time; #66 terminal `agent/blocked` after 1 round.  
**Mechanism**: `.agents/fix.yaml` hard-rules are static while `specs/TRACKS.md` lane ownership evolves. Coordinator cannot override recipe (CODEOWNERS-gated); human must amend recipe for each new lane/path conflict.  
**Process change**: In `.agents/fix.yaml`, replace the static forbidden-paths list with a dynamic reference: `forbidden_paths: [".github/", ".agents/", "CODEOWNERS", "infra/", "secrets/"]` **except** paths explicitly owned by the issue's track label per `specs/TRACKS.md` (read at runtime). Or minimally: add `track/chassis` carve-out for `.github/workflows/ci.yaml` and `track/deploy` for `chart/**` (already done for deploy).  
**Expected saving**: **2–3 human-unblock cycles per lane extension** (each costs ~1 day wall-time + coordinator rounds). Eliminates the "recipe vs. charter" deadlock class entirely.

### 5. Haiku infra strikes misclassified as "unknown", hide token-expiry pattern
**Evidence**: #29 (2×), #43, #42, #52, #47 r1 all show `AGENT_STRIKE: error_class=unknown` for haiku. But #29 meta-arbitration revealed root cause: turn-cap 80 (raised to 200). #1 meta-coordinator revealed: free-model pace (2917s) outlives 60-min GitHub token TTL. #52: `ConnectionRefused` during nixpkgs pull. Ledger: `worker_exits` shows "failed" for #29, #43, #42 but terminal `agent/done` — exit code unreliable.  
**Mechanism**: The strike classifier only knows "budget-403" and "token-expiry" (FU-021). Turn-cap, auth-storm, nixpkgs-pull timeout, and token-TTL expiry all fall through to "unknown". No retry policy distinguishes transient infra from model failure.  
**Process change**: In the strike classifier (agent-finalize logic), add two rules: (a) if `max_turns` reached → `error_class: turn-cap`; (b) if wall_time > 50min and GitHub token TTL is 60min → `error_class: token-ttl-expiry`. Extend FU-021 hard-stop to cover `turn-cap` and `token-ttl-expiry` (don't re-dispatch same model).  
**Expected saving**: **2–3 wasted re-dispatches per haiku scaffold task** (each burns ~5–10 min pod startup + queue wait). For #29: 2 strikes → 2 infra cycles → ~10 min saved per occurrence.

### 6. Wall-time outlier #8 (193,579s = 53.8h) is coordinator queue wait, not model time
**Evidence**: #8 (rank 3) ledger: 2 rounds, both `ci_sequence: [true, true]`, both `worker_exits: ["clean", "clean"]`, `wall_time_s: 193579`. Issue trail: round 1 dispatched → PR opened → reviewer CHANGES_REQUESTED → round 2 dispatched → fix → green → merge. The 53h is elapsed from first dispatch to merge, not model runtime. Most tasks show `wall_time_s: 0` (unmeasured).  
**Mechanism**: `wall_time_s` appears to be coordinator's `now - task_created_at` at ledger write, not sum of worker runtimes. It captures queue depth, reviewer latency, coordinator tick interval — not the loop's actual cost.  
**Process change**: In the ledger writer, replace `wall_time_s` with two fields: `worker_wall_time_s` (sum of pod runtimes from `AGENT_RUN_STATS`) and `queue_wait_s` (dispatch-to-first-pod-start + inter-round gaps). Emit both from coordinator's existing timestamps.  
**Expected saving**: **Enables identifying true bottlenecks** — currently #8 looks like a "slow task" but is actually "slow queue/review". No direct round saving, but **prevents misattribution** of wall-time to model choice.

## Proposed process changes (table: change | artifact | expected saving | confidence)

| Change | Artifact | Expected saving | Confidence |
|--------|----------|----------------|------------|
| Hard reject tool calls >2000 chars | `.agents/fix.yaml` (add `pre_tool_hook` or `checks:` clause) | 2 deepseek rounds × $0.12 + 3h wall-time per scaffold task | HIGH (root cause confirmed, fix is structural) |
| Increment reviewer_rounds on reviewer verdict | `coordinator-scan.sh` / ledger writer (1-line jq) | Enables review-loop measurement; catches missing reviewer dispatch | HIGH (trivial code change, data model exists) |
| Always emit budget_tier/cap/est at dispatch | Budget estimator / dispatch path | Full calibration traceability for 100% tasks (vs 10% now) | HIGH (estimator exists, just not wired for haiku/free) |
| Dynamic forbidden-paths from TRACKS.md lane ownership | `.agents/fix.yaml` (replace static list) | Eliminates 2–3 human-unblock cycles per new lane/path conflict | MEDIUM (requires reading TRACKS.md at runtime; recipe is static YAML) |
| Classify turn-cap & token-ttl-expiry in strike classifier | Agent-finalize / strike classifier logic | 2–3 wasted haiku re-dispatches per scaffold task (~10 min each) | HIGH (classifier exists, just missing two rules) |
| Split wall_time_s → worker_wall_time_s + queue_wait_s | Ledger writer / coordinator timestamps | Prevents misattribution; enables true bottleneck identification | MEDIUM (needs coordinator timestamp plumbing) |

## Evidence confidence (what you could NOT verify and why)
- **Reviewer bot latency**: Cannot measure reviewer turnaround time because `reviewer_rounds=0` in ledger and no timestamp on reviewer comments in issue trails. Would need GitHub API `gh api /repos/.../pulls/.../reviews` with timestamps.
- **Haiku actual cost**: Ledger shows $0.00 for all 29 haiku tasks — unclear if truly free (OpenRouter free tier) or below reporting threshold. No billing data available.
- **Deepseek auth-storm root cause**: #1 shows 401 "User not found" storm after truncation, but unclear if truncation → retry → auth-storm is causal or coincidental. No worker log for the auth-storm round (r3 died pre-push).
- **CI).
- **Queue depth vs. coordinator tick**: #8's 53h wall-time could be coordinator tick interval (unknown) + reviewer latency + queue. No coordinator log to isolate.
- **Retry_storms=0 for all**: Unclear if this field is never populated or genuinely zero. No infra retry metrics visible in issue trails.
