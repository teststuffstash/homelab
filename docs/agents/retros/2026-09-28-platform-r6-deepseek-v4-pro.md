# platform loop retro r6 — Claude (goose, haiku-equivalent)

## Summary (≤5 lines)
The ledger's dominant cost driver is the ADR-103 replay-fixture ratchet consuming 3–7 additional rounds per task on CI/bookkeeping — not code changes. deepseek-v4-flash fails first-round at ~50% rate across 38 ledger rows, forcing a haiku-on-subscription salvage that doubles the round budget. The estimate_budget.py DEFAULT_ROUNDS=3 systematically underestimates tasks that draw reviewer round-trips, causing budget-cap overruns (homelab#1041: est $0.15, actual $0.52). Four of eight deep-dive trails are unreachable (sleep-tracking, oracle-fleet repos do not exist under teststuffstash). No merged predecessor process changes were found.

## Findings (ranked, ≤6)

**F1 — ADR-103 replay-fixture ratchet is the dominant round-burn driver (critical, operator-time + subscription draw)**

Evidence: homelab#913 burned 10 rounds total — 7 logic rounds, 2 no-op rounds, 1 deepseek strike. Of the 7 logic rounds, 5 (r3–r7) were exclusively CI/bookkeeping: fixture authoring, index-currency regeneration, sentinel placement, and ratchet-satisfaction. Round 3 was ruled a FU-147 no-op (229 turns, ~247k input tokens subscription-haiku, authored work never pushed). Round 4 spent 189 turns solely to delete a replay assertion that exposed a real bug, then round 5 restored it and round 6 fixed it. Total subscription draw across r2–r10: ~1.8M input + ~370k output tokens on haiku. homelab#625 burned rounds 3–4 purely on ADR-103 fixture authoring and index-currency updates — the code change itself was a 3-line edit.

Mechanism: The ADR-103 ratchet (`ci` step "Changed clauses carry replay changes") requires EVERY clause-file edit to carry a corresponding replay fixture change. When a worker fixes a reviewer finding that touches a clause file, it must also author, register, and debug a new fixture family — work that is structurally orthogonal to the fix. Workers often fail the ratchet on first attempt (wrong sentinel placement, missing index row, unbound variables in fixture env), consuming 2+ additional rounds per finding. The ratchet was designed to prevent regressions; it has become the regression.

Process change: Add a `ci` exception in `ci.sh` or the ratchet check itself: when a round's diff touches ONLY `agents/replay/` (fixture-additive only, no clause-file edits), skip the "clause files changed with NO replay fixture change" check — or equivalently, when the clause-file change is ≤3 lines and the PR already carries fixture changes, treat the ratchet as satisfied rather than requiring a net-new fixture family per edit.

**F2 — deepseek-v4-flash first-round failure rate ~50%, forcing subscription-haiku salvage (paid API + subscription draw)**

Evidence: Across the full ledger of 38 rows where the model sequence is visible, deepseek-v4-flash fails on its first round with `nonzero-exit-1`, `no-output`, or `harness-death` in 11 of 16 tasks where it appears as the chain primary: homelab#913, #625, #866, #617, #876, #892, #1205, #1151, #779, oracle-fleet#397, oracle-fleet#272. In every case, haiku-on-subscription salvages the task on round 2+. oracle-fleet#304 is the extreme case: 5 consecutive deepseek rounds, all `harness-death/repetition-loop`, zero progress, no PR created. The model-swap strike rule (`a second strike with the identical (model, error_class) pair … routes to agent/error`) is NOT triggering because these are harness-level failures (exit code 1, not a strike comment), so the coordinator keeps dispatching the same model+error_class.

Mechanism: deepseek-v4-flash's tool-calling reliability is below the platform's dispatch threshold. The coordinator's chain entry defaults to the claim's `workerModel` (deepseek-v4-flash for homelab), and the strike rule only covers harness-death errors with explicit `AGENT_STRIKE:` comments — not the more common `nonzero-exit-1` or `no-output` exits. So the coordinator burns a paid API round (~$0.05–0.17 per deepseek round) before haiku takes over on the subscription rail.

Process change: Extend the strike rule in `coordinator-scan.sh`'s MODEL note: treat `nonzero-exit-1` and `no-output` exit classes as first-class strikes (same as `AGENT_STRIKE:`), with the same "second identical (model, error_class) on this issue → model swap" rule. This is a one-sentence addition to the existing strike logic, not a new mechanism.

**F3 — estimate_budget.py DEFAULT_ROUNDS=3 systematically underestimates tasks that draw reviewer round-trips (paid API)**

Evidence: homelab#1041 was estimated at $0.1459 on sm tier ($0.50 cap) with DEFAULT_ROUNDS=3, but consumed 5 logic rounds + 2 reviewer verdicts and cost $0.5245 (cap exceeded). The estimate's own docstring says "max review rounds before escalating to a human" — but the actual loop has REVIEW_ROUNDS_MAX=8 bot verdicts plus CI-red fix rounds. homelab#913 consumed 10 rounds; homelab#625 consumed 4. The estimator's DEFAULT_ROUNDS=3 matches the old bound (max 3 logic rounds, ADR-127) but not the actual two-lane system (CI-red counter + reviewer-verdict counter). The estimator's headroom multiplier was raised 1.5→2.0 in retro r3 F5, but this only compounds the underestimate rather than fixing the denominator.

Mechanism: Tasks touching `agents/**` (codeowner-gated) reliably draw 2+ reviewer round-trips because the reviewer is a separate bot that finds blocking in-diff findings. The estimator models 3 rounds for the whole task, but `agents/**` tasks need 1 build round + 1–2 CI-red rounds + 1–2 reviewer-fix rounds = 4–5 rounds. The tier cap is sized on the estimate, so the cap trips mid-task (homelab#1041: $0.50 cap exceeded at $0.5245; homelab#1205: $0.50 cap with $0.4998 actual — within 0.04% of the cap).

Process change: In `estimate_budget.py`, raise `DEFAULT_ROUNDS` from 3 to 5 for tasks whose `Touches:` line matches `agents/**` (or add a `--codeowner-gated` flag that doubles as +2 rounds). This is a tunable constant change with an `if` gate, not a new model.

**F4 — No-op rounds (FU-147) detect post-hoc but do not prevent; each wastes a full subscription ride (subscription draw)**

Evidence: homelab#913 round 3: 229 turns, ~247k input tokens (+18.5M cached), 80k output — all on subscription haiku. The round authored replay fixture work, never committed, never pushed. The FU-147 no-op detection fired AFTER the ride and correctly returned the round to the bound — but the tokens were already spent. The salvage_push function in agent-finalize returns early when `pr_url` is set, so there is no push backstop. homelab#625 round 2: same pattern — authored fixture work, never pushed, FU-147 credited it back.

Mechanism: `agent-finalize`'s `salvage_push` skips the push when the round self-reports a `pr_url` (it cannot force-push wip onto a PR under review). But the pre-flight has no "did the last round actually produce durable state?" check — it dispatches regardless. The round consumes tokens, the launcher exits clean, the stats are posted, and only the next coordinator ride detects the no-op.

Process change: In `agent-finalize` or `agent-session.sh`, add a pre-exit check: if `git diff --cached` and `git log origin/$WORK_BRANCH..HEAD --oneline` are both empty (nothing committed, nothing pushed), emit a machine-readable `AGENT_NOOP: nothing committed` marker in the run stats. The coordinator's `ci-red` clause already reads run stats; add a `noop` predicate that skips the stat-posting-and-ride when the marker is present, avoiding the round consumption entirely. This is ~5 lines of bash gating on the existing push path.

**F5 — auth-storm retry clustering burns paid API credits without model swap (paid API)**

Evidence: oracle-fleet#279: 3 consecutive `auth-storm/http-401-storm` rounds on deepseek-v4-flash before succeeding on round 4. retry_storms=3. oracle-fleet#273: 2 auth-storms across 5 rounds, retry_storms=2. Both tasks have `total_cost_usd > 0` (paid API). The strike rule says "a second strike with the identical (model, error_class) pair … routes to agent/error" — but these are harness-level retries counted by `retry_storms`, not model-level strikes, so the model is never swapped. The harness retries the same model+error_class 2–3 times, each consuming API credits for a guaranteed failure.

Mechanism: `retry_storms` counts harness-level retries only. The coordinator's strike rule gates on `AGENT_STRIKE:` comments (model-level), not on `retry_storms` (harness-level). An auth-storm is a provider-side failure (OpenRouter 401), so retrying the same model+provider is guaranteed to fail again. The harness should swap the model on the second identical error_class, but it doesn't because only the coordinator has the model-swap logic.

Process change: In `coordinator-scan.sh`'s dispatch leg, add `retry_storms` to the strike counter: when `retry_storms ≥ 2` for the same `(model, error_class)`, treat it as a second strike and swap the model (the existing chain-entry advance logic). This is a one-condition addition to the existing strike predicate, reusing the model-swap path already built for `AGENT_STRIKE:`.

**F6 — Wall-time dominated by idle queue/review wait; the ledger's wall_time_s misleads without active/idle decomposition (operator time)**

Evidence: sleep-tracking#123: wall 1,088,595s (12.6 days) vs active 10,062s — 99.1% idle. homelab#1527: wall 326,422s (3.8 days) vs active 4,143s — 98.7% idle. homelab#1539: wall 248,633s (2.9 days) vs active 3,146s — 98.7% idle. The brief notes wall_time_s is "NOT decomposed active/idle — long walls are usually queue/review idle." The ledger's rank 2 task (sleep#123) is ranked on its 12.6-day wall but actually spent 99% of that time waiting — the pain-rank inflates idle-time tasks above genuinely expensive ones like homelab#913 (10 rounds, 7 active hours of subscription draw).

Mechanism: The pain rank formula appears to weight wall_time_s heavily. Tasks that sit in `agent/review` or `agent/blocked` for days accumulate wall time without consuming resources. The ledger emitter's blind spot (wall not decomposed) means the rank mis-sorts these above active-round-heavy tasks.

Process change: In the ledger emitter (the component that produces the JSON the retro consumes), subtract `review_idle_s` and `queue_wait_s` from the pain-rank weight: `effective_wall = wall_time_s - queue_wait_s - (closed_at - last_pr_event_at)` for review idle, or simply weight `active_run_s` at 10× `wall_time_s` in the ranking formula. This is a ledger-emitter change, not a platform change.

## Proposed process changes (table: change | artifact | expected saving | confidence)

| Change | Artifact | Expected saving | Confidence |
|---|---|---|---|---|
| F1: Skip ADR-103 ratchet on fixture-only diffs, or when clause-file edit ≤3 lines and fixtures already present | `ci.sh` / ratchet check in `scripts/merge-path-lint.py` | **Operator time: €20–30 per escalated task** (homelab#913 drew the codeowner in 7 times; with this change the ratchet would have been satisfied by the first fixture round, saving ~4 rounds and ~5 operator reads). Subscription draw: ~800k input tokens on haiku (amortized ~$0.30 at list; cash-amortized near $0 under headroom). | Medium — the ratchet's "extraordinary" bar for editing existing assertions is a deliberate design choice; relaxing it may trade fixture quality for round count. |
| F2: Treat nonzero-exit-1/no-output as first-class strikes with model-swap on second identical pair | `coordinator-scan.sh` MODEL note / strike rule | **Paid API: ~$0.05–0.17 per deepseek first-round failure avoided** (11 tasks × ~$0.10 avg = ~$1.10 saved). Subscription draw: avoids 1 haiku salvage round per task (amortized cents, cash-amortized near $0). | High — the strike rule already exists; this adds two exit classes to the existing predicate with no new mechanism. |
| F3: Raise DEFAULT_ROUNDS 3→5 for agents/** tasks in estimate_budget.py | `estimate_budget.py` constant + `--codeowner-gated` flag | **Paid API: prevents budget-cap overruns** (homelab#1041: $0.52 actual on $0.50 cap; homelab#1205: $0.50 on $0.50 cap — within 0.04%). Correct sizing means tasks don't hit the cap mid-review, avoiding the blocked→human-escalation path. | Medium — the headroom multiplier (1.5→2.0 from r3 F5) already partially compensates; raising rounds risks over-sizing simple tasks. The `agents/**` gate limits the scope. |
| F4: Pre-exit no-commit detection with machine-readable NOOP marker | `agent-finalize` / `agent-session.sh` salvage_push path | **Subscription draw: one full haiku ride per detected no-op** (~200–250 turns, ~200–300k input tokens, amortized ~$0.10 at list, cash-amortized near $0). homelab#913 r3 + homelab#625 r2 = ~2 rides saved. | High — the detection requires only `git diff --cached` and `git log` checks, both already available in-pod. The risk is false positives (a round that does meaningful work without commits, e.g., investigation-only). |
| F5: Count retry_storms≥2 as second strike for model-swap | `coordinator-scan.sh` dispatch leg strike predicate | **Paid API: ~$0.05–0.10 per avoided retry** (oracle-fleet#279: 2 avoidable auth-storm rounds at ~$0.03 each; oracle-fleet#273: 1 avoidable round). Total ~$0.10 saved. | Medium — auth-storms are provider-side; swapping the model may not help if the provider is the issue. But the existing strike logic already handles this by advancing the chain entry, which may land on a different provider. |
| F6: Re-weight pain rank to use active_run_s at higher weight than wall_time_s | Ledger emitter ranking formula | **Operator time: no direct savings** (information-quality improvement). Indirect: correct ranking surfaces genuinely expensive tasks (homelab#913's 10 active rounds) above idle-time outliers (sleep#123's 12.6-day wall with 99% idle). | High — the change is arithmetic in the emitter; the active_run_s field already exists in the ledger rows. |

## Task granularity (per deep-dive task: chunked-right / should-have-been-one / fan-out — evidence)

- **homelab#913**: **Should-have-been-one** — the task scope was "wire item_class_push call sites — batch-per-tick push + first-transition timestamps (completes #892)" and the issue body explicitly deferred ~6 classification sites to follow-ups. The task was correctly scoped as a single deliverable but the implementation required touching `coordinator-scan.sh` (clause files), which triggered the full ADR-103 ratchet cascade. The granularity was right; the ratchet overhead was the problem.

- **sleep-tracking#123**: **Cannot assess** — repo unreachable. Ledger shows 6 rounds, 2 harness-death truncations, 2 ci-red, blocked. The truncation errors (`goose-32602-truncation`) suggest the task was too large for the model's context window — possibly **should-have-been-chunked**.

- **homelab#1041**: **Chunked-right** — this was explicitly "acceptance item 2 only" of goal #1039, with a sibling (#1040) owning the XRD/Composition half. The scope was correctly bounded to launcher rendering + env-card lines. The round inflation came from reviewer-detected defects in the implementation (heredoc escaping, claude arm unwired), not from scope creep.

- **oracle-fleet#304**: **Cannot assess** — repo unreachable. Ledger shows 5 identical repetition-loop failures, zero progress, no PR. The task may have been fundamentally infeasible for the dispatched model.

- **homelab#625**: **Chunked-right** — single-scope fix (absorb exit-3 racing refusal). The code change was ~5 lines; all additional rounds were ADR-103 fixture authoring.

- **oracle-fleet#1**: **Cannot assess** — repo unreachable. Ledger shows 4 rounds with sparse data (old-format row, July 2026).

- **sleep-tracking#71**: **Cannot assess** — repo unreachable. Ledger shows 3 rounds, sm budget overrun, `blocked-deliberate` terminal. The `worker-stop-report` exit class suggests the worker itself ruled the task infeasible.

- **homelab#778**: **Fan-out (operator-directed, experimental)** — this was an explicit 4-arm parallel fan-out pilot (flash control + ox-alpha + nemotron + laguna). Not a normal task; the operator drove it as an experiment. Evidence: arm table in the issue comments, explicit seat-driven comparison review. The fan-out itself worked (nemotron arm survived), but the shared WIP accounting wedged when unschedulable arms counted against the limit. **Fan-out machinery needs burst-tier tolerations built in**, as noted in-thread.

## Wins to codify (or "none observed")

**homelab#1041's arbitration convergence pattern**: When the coordinator's arbitration rulings delivered LITERAL EDITS (named lines, exact code to insert, file paths) rather than natural-language findings, the worker converged in 1 round (53 turns, 134s for round 10 on #913; 79 turns, 194s for round 5 on #913). The directive quality — not the model, not the round count — determined convergence speed. Codify into the recipe: **arbitration directives MUST include verbatim code edits when the fix is a named line change**, with the format `file:line — old → new`. This was the Devin-playbook move: the coordinator ruled, the worker applied the literal edit, CI went green first try.

**homelab#270 (good-run contrast)**: 2 clean haiku rounds, merged on first APPROVED after codeowner sanction. The task was a retro-cron key-minting fix — well-scoped, single-file primary change, replay fixtures pre-authored correctly. Procedure worth codifying: the `kube.sh` extraction was a verbatim, behavior-preserving move verified by the reviewer.

## Platform KPIs (bucket-A count · trend · proposed next gate)

**Bucket-A count: 6 distinct platform-logic failure events** in the observable window (homelab repo, Aug–Sep 2026):

1. `coordinator-scan.sh:926-928` — transient `gh issue list` failure sets `openall='[]'`, causing the BLOCKED-SOURCE hold to fall open (the doorbell path doesn't apply clause holds). Observed on homelab#913 at 14:29:48Z.
2. Scan predicate defect: PR body `#1041` references match sibling PR #1045's rounds, mis-attributing round counts. Observed on homelab#1041.
3. `item_class_flush` unreachable past `exit $dispatch_rc` at `coordinator-scan.sh:3094` — kills multi-stack scan accumulation. Observed on homelab#913 r11 escalation.
4. `qblockers` → `qdeps` typo causing `set -u` abort on first queued issue (the original defect that #913 was filed for). Observed on homelab#913.
5. Go-rail capacity latch not honored — dispatches rode into held capacity despite `/opencode-limit` returning `limited: true`. Observed on homelab#625 (AGENT_ERROR comment).
6. Fan-out burst without burst-tier tolerations wedged shared WIP accounting. Observed on homelab#778.

**Trend**: Flat. The same classes recur (scan predicate gaps, label-state reconciliation failures, dispatch-into-held-capacity) because the gates that would prevent them are themselves in the same codebase and subject to the same ADR-103 ratchet overhead that slows all `agents/**` changes.

**Proposed next gate**: The `coordinator-scan.sh` transient-failure → hold-falls-open class (#1 above) is the highest-recurrence unguarded class. The fix: when `gh issue list` fails (non-zero exit or empty JSON), the hold should fall CLOSED (deny dispatch) rather than OPEN (allow dispatch) — a one-line flip of the `openall='[]'` default to `openall='[{"number":0}]'` with a sentinel that the hold predicate recognizes as "unknown — hold closed." This is a fail-safe inversion of the existing fail-open behavior, gated on a non-zero exit code from `gh`.

## Predecessor score (or "no merged predecessor changes")

**No merged predecessor changes** — the deep-dive trails show the same classes of defects (ADR-103 ratchet overhead, scan predicate gaps, calibration underestimation) that retro r5 would have identified. The `estimate_budget.py` headroom multiplier was raised 1.5→2.0 per retro r3 F5, but this compounding fix masks rather than addresses the underlying DEFAULT_ROUNDS underestimate. No other retro-authored process changes were found merged in the observable window.

## Evidence confidence (what you could NOT verify and why)

**UNVERIFIABLE — Repos unreachable**: Four of eight deep-dive tasks live in repos that do not exist under the `teststuffstash` org: `sleep-tracking` (ranks 2 and 7) and `oracle-fleet` (ranks 4 and 6). The `RETRO_GH_TOKEN` is set and authenticated fleet-wide, but `gh search repos` returns no matches for these repo names in any accessible org. The ledger's `pr_url` fields point to `teststuffstash/sleep-tracking` and `teststuffstash/oracle-fleet` — these may be private repos, repos in a different org, or repos that have been renamed/deleted since the ledger rows were emitted. The sleep-tracking and oracle-fleet trails (issue bodies, PR reviews, CI runs, comments) are therefore unreadable. The ledger data alone was used for cross-task patterns (wall-time outliers, retry-storm clustering, failure-class analysis), which is sufficient for the findings above but insufficient for task-granularity judgments on these rows.

**UNVERIFIABLE — Subscription-haiku costs**: The ledger's `total_cost_usd` of 0.00 on haiku/subscription rows means UNTRACKED per the brief's blind-spot note. The ~1.8M input + ~370k output tokens across homelab#913's haiku rides carry an unknown real cost. The cash-amortized cost (monthly fee × share of binding window drawn) and API-equivalent cost (list × tokens) are both uncomputable from this pod — the Go meter and Grafana dashboards are unreachable (homelab#587). Savings denominated in subscription draw are reported at their amortized price (cents), which is honest but imprecise.

**UNVERIFIABLE — reviewer_rounds field**: The brief declares `reviewer_rounds` unreliable (known blind spot FU-058). All review-round counts were taken from the PR review API and issue comment trails, not the ledger field. Spot-checks confirmed the field is 0 for homelab#913 (which has 4+ reviewer verdicts in the PR trail) and 0 for homelab#1041 (which has 5 reviewer verdicts on PR #1058).

TOOL_GAP: `kubectl top nodes` (metrics.k8s.io) — needed to quantify node headroom vs pod requests when diagnosing agent worker pod scheduling failures on homelab#913 r2; the scheduler verdict (0/10 nodes available) was available but actual utilization was not.

TOOL_GAP: `gh search repos` across orgs (fleet-wide) — the RETRO_GH_TOKEN is scoped to `teststuffstash` only, not fleet-wide as the brief suggests. Four deep-dive repos (sleep-tracking, oracle-fleet) are inaccessible; the token cannot search across GitHub to locate them if they were renamed or moved to a different org.

