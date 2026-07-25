# Oracle loop retro r1 — Claude Opus 4.8

## Summary (≤5 lines)
The loop rarely loses rounds to task difficulty; it loses them to **harness/policy plumbing**. Three recurring taxes dominate: (1) `.agents/fix.yaml` path-bans that contradict the `TRACKS.md` lane charter, fixed point-wise for `chart/` but still deadlocking `.github/`; (2) a strike emitter that stamps `error_class=unknown` on clean successes and deliberate stops, triggering needless model-chain redispatch; (3) `deepseek-v4-flash` truncating large file writes on scaffold work. Underneath all of it, cost/wall/round telemetry is largely null (haiku cost = $0.0 in ~28/32 tasks), so budget calibration is degenerate and none of the above is auto-detectable.

## Findings (ranked, ≤6)

**F1 — Recipe path-ban vs TRACKS lane charter: fixed for `chart/`, still deadlocks `.github/`.**
- *Evidence*: `.agents/fix.yaml:61-63` bans `.github/, .agents/, CODEOWNERS, infra/` and now carves out `chart/` **only** for `track/deploy` (added after #47). #47 blocked **three times** (round-1, 2026-07-18 re-block, post-rescope re-block) + two human META arbitrations before the `chart/`/`track/deploy` carve-out landed. #66 (`track/chassis`) then hit the *identical* shape on `.github/workflows/ci.yaml` — which `TRACKS.md` assigns to `track/chassis` — and is permanently `agent/blocked`, 0 delivered.
- *Mechanism*: the ban list is a static blocklist patched one class at a time instead of being derived from the per-lane ownership already declared in `TRACKS.md`; every new lane×path collision re-deadlocks and re-escalates.
- *Process change*: in `.agents/fix.yaml` replace the blanket `.github/` ban with a `track/chassis` carve-out for `.github/workflows/ci.yaml` (same shape as the `chart/`/`track/deploy` clause), and confirm the app token carries `workflows` scope.
- *Expected saving*: unblocks #66's whole class; eliminates the repeat block→human-META cycle (≥3 coordinator ticks + 2 human interventions observed on #47 alone).

**F2 — `AGENT_STRIKE error_class=unknown` misclassifies clean/deliberate exits → needless chain-walk.**
- *Evidence*: #29 re-dispatch (`agent-oracle-fleet-142409`) posted `AGENT_STRIKE ... error_class=unknown` whose own detail block is a **full success** (CI 97 passed, PR #48 opened, spec changes done); ledger `worker_exits:[failed,failed]` yet `terminal:agent/done`. #66's worker deliberately stopped with a structured `{"summary":…,"ci_passed":false}` report, then a strike fired anyway — the coordinator wrote "the AGENT_STRIKE ... misclassifies what happened" and manually overrode redispatch. #47/#52 strikes were pure infra (nixpkgs unpack death; `ConnectionRefused`). `unknown` is the catch-all for successes, policy-stops, infra crashes, and turn-cap deaths alike.
- *Mechanism*: the strike path defaults to `error_class=unknown` whenever it can't parse `AGENT_RUN_STATS`, and the `c4c5-redispatch` clause treats *any* strike as "walk the model chain" — so finished and deliberately-stopped runs get re-run on the next model.
- *Process change*: gate the redispatch clause on the worker's finalize payload — if a finalize JSON (`pr_url`/`ci_passed`/`files_changed`) or a resumable branch+PR exists, classify as done/blocked-deliberate and **do not** emit `unknown` or walk the chain (encode what #66's coordinator did by hand).
- *Expected saving*: ≥1 redundant worker round per event; #29 ran a full duplicate 200-turn haiku round, #66 avoided a manual 3-model walk. ≥2 events in 32 tasks.

**F3 — `deepseek-v4-flash` truncates monolithic file writes; instruction guardrails don't bind it.**
- *Evidence*: #1 (rank 1, 4 rounds, `agent/blocked`, `worker_exits:["0","0","0","0"]`, `ci:[null,true,null,null]`). Human breakdown: r1 died on a 15,267-char single tool call → truncation → `goose -32602 EOF`; r3 died the same way on a 14,781-char write. Only r2 succeeded. The recipe's "write incrementally, ≲50 lines" rule (added after r1) "did not bind the model." 3 of 4 rounds lost to one model limitation on a **scaffold** (large new files), not to difficulty.
- *Mechanism*: file-*recreation* work exceeds this model's tool-output tolerance; a prose instruction can't cap it.
- *Process change*: add a dispatch gate in the coordinator scan — scaffold/greenfield-class issues (new-file creation, no existing PR branch) are not dispatched on `deepseek-v4-flash`; route to a higher tool-output-tolerance model.
- *Expected saving*: ~2 rounds + the eventual block-escalation on #1-class scaffold tasks; #1 spent $0.248 / 13,762 s to deliver one usable round.

**F4 — Auth-401 retry storm has no breaker; the `retry_storms` metric is blind to it.**
- *Evidence*: #1 r3 hit a "401 'User not found' auth storm — goose retried a fatal auth error dozens of times (FU-021 class)," burning the session with zero recovery. Ledger `retry_storms:0` for **all 32 tasks**, including #1 — the storm wasn't counted.
- *Mechanism*: FU-021's breaker was scoped to budget-403 only; 401 auth failures are treated as retryable, so a non-recoverable error loops until the session dies, and the counter never increments.
- *Process change*: extend the FU-021 retry breaker to hard-stop on 401/403 auth-class errors, and increment `retry_storms` when it trips.
- *Expected saving*: reclaims the dozens of wasted retries + the partial round #1 r3 lost; makes storm clustering visible for future retros.

**F5 — Scaffold edge-findings get piled into sequential fix-rounds instead of approve+follow-up, against `review.md`'s own policy.**
- *Evidence*: `.agents/review.md` (pre-prod section + "Scaffold/greenfield") explicitly lists "CITE-edge cases in paths no consumer calls yet" as **APPROVE-with-Follow-up**, and cites "three rounds on PR #6 ... never converged" as the reason not to pile rounds. Yet #1 (a scaffold) routed CITE-edge breaches as **blocking** r2, whose new paths exposed fresh CITE bugs in r3, which hit the 3/3 bound → `agent/blocked`+human — exactly the PR #6 anti-pattern. Contrast #8 and #45, where the coordinator split "one blocking item only" + follow-ups and converged in 2 rounds.
- *Mechanism*: the coordinator arbitration step re-classifies edge/unhandled-shape findings as blocking on scaffold PRs, overriding the rubric that already calls them follow-ups.
- *Process change*: add a clause to the coordinator arbitration step — for scaffold/greenfield-class issues, edge-shape/CITE-edge findings route to follow-up issues, never fix-rounds; cap such PRs at one blocking fix-round (secrets/CI-red/regression only).
- *Expected saving*: eliminates #1's r3 + its block-escalation + human touch; ~1–2 rounds per scaffold PR that draws edge findings.

**F6 — Cost/wall/reviewer-round telemetry is null, so budget calibration is degenerate.**
- *Evidence*: `total_cost_usd:0.0` on every haiku row (ranks 4,5,7–32 ≈ 28/32 tasks — the dominant model); `wall_time_s:0` for ranks 6–32; `calibration_error` non-null only on the 3 `budget_tier:"md"` rows (#108/#107/#121), all `0.0` — but their actual cost is also `0.0`, so "perfect" calibration is just both-sides-zero. `reviewer_rounds:0` across all 32 despite trails full of `CHANGES_REQUESTED` loops (#1, #8, #45). Wall-time also conflates queue/dependency wait with compute: #8 `wall=193,579 s` (≈53.7 h) but its trail is days of `Depends-on`/lane-free waiting around two clean green rounds — a queueing artifact, not a slow task.
- *Mechanism*: the run-stats emitter prices only OpenRouter/deepseek runs (claude-tier reports tokens but $0 cost), records wall as pickup→done wallclock (queue included), and never counts review rounds — so the estimator has no signal for the model and shape it dispatches most.
- *Process change*: in the `AGENT_RUN_STATS` emitter, price haiku/claude-tier runs from token counts, split `wall_time_s` into `queue_wait` vs `active_run`, and increment `reviewer_rounds` on each `CHANGES_REQUESTED`.
- *Expected saving*: precondition for F3/F5 routing and any budget-tier rollout; without it calibration validates against a null cost signal (the only 3 calibrated tasks are degenerate zeros).

## Proposed process changes (table)

| Change | Artifact | Expected saving | Confidence |
|---|---|---|---|
| Carve out `.github/workflows/ci.yaml` for `track/chassis` (mirror the `chart/`/`track/deploy` clause); confirm `workflows` token scope | `.agents/fix.yaml:61-63` | Unblocks #66's class; kills repeat block→human-META cycle (≥3 ticks + 2 humans on #47) | High |
| Gate redispatch on finalize payload; don't emit `unknown`/walk chain when a PR/finalize JSON/resumable branch exists | strike emitter + coordinator `c4c5-redispatch` clause (homelab) | ≥1 redundant worker round/event; ≥2 events/32 | High |
| Don't dispatch scaffold/new-file issues on `deepseek-v4-flash` | coordinator dispatch/model-routing gate (homelab) | ~2 rounds + block on #1-class scaffolds ($0.248/13.7 ks on #1) | High |
| Extend FU-021 breaker to hard-stop 401/403 auth; increment `retry_storms` on trip | FU-021 retry breaker (homelab) | Dozens of retries + partial round (#1 r3); storm visibility | High (behavior); Med (artifact unseen) |
| Route scaffold edge/CITE-edge findings to follow-ups, cap 1 blocking fix-round | coordinator arbitration clause + `.agents/review.md` scaffold section | #1 r3 + escalation; ~1–2 rounds/scaffold PR | Med-High |
| Price claude-tier by tokens; split wall into queue vs active; count reviewer rounds | `AGENT_RUN_STATS` emitter (homelab) | Enables cost-routing; ends degenerate 0.0 calibration | High (ledger); Med (wall split) |

## Evidence confidence (what I could NOT verify)
- **True token/$ costs**: `total_cost_usd` is 0.0 for all haiku runs and no token telemetry surfaced in the issue trails, so every dollar figure except deepseek rows is unquantifiable — savings are stated in rounds, not $.
- **Homelab-side artifacts**: `coordinator-scan.sh`, the strike emitter, the FU-021 breaker, and the `c4c5-redispatch` clause live in the homelab coordinator brief, not this checkout — I named them from the issue comments; exact clause names/locations are inferred, not read.
- **Round accounting**: #47's ledger `rounds:3` coexists with trail comments saying blocks consumed "no round" — I mapped `rounds` to the final successful fix+review cycle; the emitter's exact counting rule is unconfirmed.
- **`reviewer_rounds:0` / `retry_storms:0`**: I treat these as *uninstrumented* because trails directly contradict them (CHANGES_REQUESTED loops on #1/#8/#45; the #1 r3 auth storm). I cannot prove "uninstrumented" vs "genuine zero" without the emitter source.
- **Wall-time split for #8**: the 53.7 h → queue-wait inference rests on the dependency-gated trail (PR #37 merge + lane-free waits); I could not measure the true compute-vs-wait breakdown.
