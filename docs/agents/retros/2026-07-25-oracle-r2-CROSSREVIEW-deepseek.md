# Cross-review of oracle retro r1 (opus report) — by Goose (Claude-based)

## Per-finding verdicts

**F1 — Recipe path-ban vs TRACKS lane charter: PARTLY agree.**

- *Verified:* `.agents/fix.yaml` does contain a hard rule banning `.github/`, `.agents/`, `CODEOWNERS`, `infra/`, and `chart/` (with a `track/deploy` carve-out for `chart/**`). Issue #47 trail confirms the chart/ deadlock: the coordinator blocked three times (first at round-1, re-blocked 2026-07-18, re-blocked post-rescope) before RasmusSoot issued exactly ONE human META that amended the recipe. Issue #66 trail confirms the identical `.github/` deadlock — the worker explicitly called it out, and the coordinator overrode redispatch to `agent/blocked`.
- *Disputes:*
  1. **Path is wrong.** The report uses `specs/TRACKS.md` throughout, but the actual file is `docs/process/TRACKS.md`. The recipe itself correctly references `docs/process/TRACKS.md` (per its `chart/` carve-out comment). A process change referencing `specs/TRACKS.md` would point to a file that doesn't exist.
  2. **Human META count off.** The report says "two human META arbitrations" on #47. The trail shows one META that actually resolved the policy (RasmusSoot's "META (unblocking)" amending fix.yaml on master). The earlier "META (rescope)" changed the task scope but did NOT address the chart/ ban — the coordinator's very next comment re-blocked on the identical unresolved policy conflict.
  3. **Line reference is fictional.** The report cites `.agents/fix.yaml:61-63` — this is a YAML with free-text `instructions:` blocks, not numbered lines, and the ban is spread across prose, not at a specific line range.
- *Substance is sound:* The core mechanism (static blocklist patched case-by-case instead of derived from TRACKS.md lane ownership) is correctly diagnosed. `.github/workflows/ci.yaml` IS listed under `track/chassis` ownership in `docs/process/TRACKS.md`.

**F2 — AGENT_STRIKE error_class=unknown misclassifies clean/deliberate exits: AGREE.**

- *Verified:* #29 second strike (`agent-oracle-fleet-142409`) carries `error_class=unknown` while its detail block shows "97 passed," CI green, PR #48 opened, spec changes done — an unambiguous full success (#29 comments). #66's worker stopped deliberately with a structured JSON finalize payload, yet `AGENT_STRIKE error_class=unknown` fired anyway; the coordinator explicitly wrote "the AGENT_STRIKE ... misclassifies what happened" (#66 comments). #47's strike was nixpkgs unpack death (infra) (#47 comments).
- *Nuance:* The report says "#29 ran a full duplicate 200-turn haiku round." The first 80-turn round was cut short and wasted. The second 200-turn round *succeeded completely* — it wasn't a "duplicate" so much as the task being completed on the second attempt after a turn-cap increase. The *waste* was the 80-turn cap, not the 200-turn completion. Also, the human META on #29 explicitly prevented a model-chain walk (`"do NOT walk the model chain"`), so the "needless chain-walk" default was averted by intervention, not auto-detected.
- *Mechanism assessment is sound:* Defaulting to `unknown` as a catch-all and treating any strike as "walk the chain" is the correct diagnosis.

**F3 — deepseek-v4-flash truncates monolithic file writes: PARTLY agree.**

- *Verified:* #1 r1 died on 15,267-char tool call, r3 died on 14,781-char write, only r2 succeeded (#1 human breakdown comment). The recipe's "write incrementally, ≲50 lines" rule is present in `fix.yaml` and did not prevent the truncations.
- *MAJOR OMISSION — root cause was platform, not model:* The #1 trail reveals that a meta-coordinator (RasmusSoot) later found the true root cause: all three truncations occurred at ~4k tokens because of a `max_tokens=4096` default in the goose→OpenRouter path. The fix was deployed: "the egress proxy now injects a max_tokens floor of 16384 into every goose completion (homelab `fa05517`)" (#1 comments, "STRIKE ANNULLED" entry). The report attributes truncation to "this model's tool-output tolerance" when it was actually a configuration ceiling that would have affected *any* model routed through that proxy path.
- *Process change concern:* The proposed gate ("don't dispatch scaffold issues on deepseek-v4-flash") may be unnecessary if the proxy fix resolves truncation. It could prematurely retire a fast model from scaffold work based on a symptom whose root cause was elsewhere. The report should at minimum condition this gate on "if the 16384-token floor is verified insufficient."

**F4 — Auth-401 retry storm has no breaker: AGREE.**

- *Verified:* #1 human breakdown explicitly states "a 401 'User not found' auth storm — goose retried a fatal auth error dozens of times (FU-021 class)" (#1 comments). The same comment says "FU-021 was scoped to budget-403; extend to auth-401." The report's claim that `retry_storms:0` for all 32 tasks cannot be verified (ledger not in this checkout), but the report's own Evidence Confidence section flags this limitation honestly.

**F5 — Scaffold edge-findings piled into sequential fix-rounds: PARTLY agree.**

- *Verified:* `.agents/review.md` PRE-PROD maturity section does explicitly route CITE-edge cases to follow-ups, not blocking rounds — and cites PR #6 (issue #1) as the motivating example: "three rounds on PR #6 found three disjoint bug sets and never converged" (`.agents/review.md` lines 10-14). The contrast cases (#8 and #45) are confirmed: #8's round-2 dispatch shows "one blocking item only" with three explicit OUT OF SCOPE follow-ups (#8 comments); #45's round-2 dispatch similarly splits "one blocking finding" from "7 follow-up-class" items (#45 comments). Both converge cleanly at round 2.
- *Timing problem — report implies review.md was violated when it was created in response:* The review.md PRE-PROD section explicitly references PR #6's three-round non-convergence AS the reason for the policy. The policy was enacted on 2026-07-10 (per review.md header and RasmusSoot's "Merge-forward arbitration" comment), after #1's rounds 1-3 completed on 2026-07-09. So #1 did not *violate* review.md's policy — review.md's policy was *written because of* #1. The report's framing as "against review.md's own policy" is anachronistic.
- *Mechanism assessment is still sound:* The report correctly identifies that the coordinator arbitration step re-classified follow-up-class findings as blocking on #1. The fact that the policy now exists to prevent recurrence doesn't diminish the finding.

**F6 — Cost/wall/reviewer-round telemetry is null: PARTLY agree (can't verify ledger).**

- *Verified (indirectly):* The report's own Evidence Confidence section acknowledges that true token/$ costs are unverifiable from this checkout. The ledger rows are not accessible. The report's reasoning is internally consistent and the hedging is appropriate.
- *Plausible but unverified:* The claim that `reviewer_rounds:0` across all 32 tasks despite CHANGES_REQUESTED loops on #1, #8, #45 is consistent with the issue trails I can see — those clearly have multiple review rounds. The `wall_time_s:0` for ranks 6-32 is untestable.
- *Conflation concern:* The report says `calibration_error` on the three md-tier rows is "both-sides-zero" — but this is the report's inference, not directly observed, since the report itself can't see token counts. It's a reasonable inference but should be marked as such.

## What the report missed

1. **Systematic path error: `specs/TRACKS.md` does not exist.** The actual path is `docs/process/TRACKS.md`. The recipe correctly references `docs/process/TRACKS.md` in its chart/ carve-out comment. Every cross-reference to this path in the report (F1, the process change table, and the summary) is wrong. If someone follows the report to find TRACKS.md at `specs/`, they won't find it.

2. **#1 truncation root cause (max_tokens=4096 proxy ceiling) is completely omitted from F3.** The #1 trail explicitly attributes truncation to a platform configuration bug, not a model limitation. The fix (egress proxy floor of 16384 tokens) was deployed and verified. By omitting this, the report over-attributes the failure to deepseek-v4-flash and proposes a process change (ban deepseek from scaffolds) that may be solving a solved problem.

3. **#47 had a fifth harness tax: subscription capacity (FU-088).** After the chart/ policy was finally resolved, dispatch was deferred because "4 subscription pods already Running ≥ max 3 (FU-088 latch)" (#47 comments). This is another case where the task was ready but harness plumbing blocked it — the report's thesis that the loop "loses to harness/policy plumbing" is correct, and this is one more data point it missed.

4. **The review.md policy chronology.** The report frames F5 as a violation of existing policy, but `.agents/review.md`'s PRE-PROD section was enacted on 2026-07-10, after #1's rounds finished on 2026-07-09. The policy cites PR #6 as its motivating example. This doesn't invalidate the finding, but it changes the nature: it's not that the coordinator overrode a pre-existing rubric, it's that there was no rubric at all, and one was created in response.

5. **#29's chain-walk was human-prevented, not automatic.** The report says #29 illustrates "needless model-chain redispatch," but the human META explicitly said "do NOT walk the model chain." The automatic mechanism would have walked it; the human stopped it. This distinction matters for understanding whether the process change (gating on finalize payload) would actually prevent the walk or just encode what the human already does.

6. **The report doesn't note that `fix.yaml`'s own anomaly circuit-breaker caused a false-positive on #47 r2.** The recipe's anomaly clause fired on a legitimate fix-round re-dispatch to an existing PR branch, consuming what would have been a productive round. This was later fixed in the recipe (RasmusSoot: "Clause fixed on master"), but it's another case of harness/policy causing a round loss — directly on-theme for the report.

## Would the process changes work as written?

**Change 1 — Carve out `.github/workflows/ci.yaml` for `track/chassis`: Workable in recipe, gated on token scope.**
The existing carve-out for `chart/`/`track/deploy` in fix.yaml is: `"chart/ is forbidden too UNLESS the issue carries the track/deploy label — that lane OWNS chart/** per docs/process/TRACKS.md"`. A mirror clause for `.github/workflows/ci.yaml` with `track/chassis` would follow identical syntax. **But** the #66 worker explicitly identified a prerequisite the report only mentions in passing: "the branch+PR-only app token cannot push `.github/workflows/**` at all (GitHub blocks workflow-file writes without `workflows` scope)" (#66 comments). The report says "confirm the app token carries `workflows` scope" — this isn't a confirmation step, it's a *blocking dependency*. Without the token scope, the recipe change achieves nothing. The path reference in the change should read `docs/process/TRACKS.md`, not `specs/TRACKS.md`.

**Change 2 — Gate redispatch on finalize payload: Sound in principle, implementation detail matters.**
The concept is correct: if the worker's finalize JSON has `pr_url`/`ci_passed`/`files_changed`, classify as done/blocked-deliberate rather than `unknown`. But the distinction is subtle: a worker that pushes a branch, opens a PR, and THEN crashes on a subsequent write should still be resumable. The gate must distinguish "completed successfully" from "crashed with artifacts" — the presence of a finalize JSON with `ci_passed:true` is a good signal, but a `ci_passed:false` with a branch pushed is ambiguous. The #66 case (deliberate stop with structured report) has `ci_passed:false` because the task was deemed unimplementable — the gate needs to handle that class too, perhaps by checking for a blocker-report shape in the finalize payload.

**Change 3 — Don't dispatch scaffold issues on deepseek-v4-flash: LIKELY OVERCORRECTS.**
The truncation root cause was a `max_tokens=4096` proxy ceiling (see Missed item #2). After the egress-proxy fix (floor of 16384), deepseek's truncation behavior may be resolved. The report doesn't mention this fix, so the proposed gate treats a platform bug as a model limitation. If the proxy fix works, this change would needlessly reduce the model pool. A better process change would be: gate on whether the proxy max_tokens floor is verified for the dispatch path, regardless of model. The report also doesn't define "scaffold/greenfield-class" precisely — "new-file creation, no existing PR branch" could match fix rounds on existing PRs that need new files.

**Change 4 — Extend FU-021 breaker to hard-stop 401/403 auth: Straightforward, directly addresses gap.**
The evidence directly supports this: the #1 trail explicitly identifies that FU-021 was scoped to budget-403 only. Extending to 401 is a narrow, well-defined change. Incrementing `retry_storms` on trip provides the visibility the report correctly notes is missing. No naming or artifact issues.

**Change 5 — Route scaffold edge findings to follow-ups, cap 1 blocking fix-round: LARGELY REDUNDANT with existing review.md.**
`.agents/review.md` already encodes exactly this: for PRE-PROD maturity, edge/CITE-edge findings are follow-ups, NOT blocking. The report proposes adding this as a coordinator arbitration clause, but the review.md policy already binds the reviewer (who generates the findings) and the coordinator (who dispatches fix rounds based on reviewer verdicts). The one new element is the "cap at 1 blocking fix-round" — but this is too aggressive. If a fix round introduces a CI regression or a new secrets leak, the coordinator MUST dispatch a second fix round regardless. The #8 case shows a round-2 fix working within 2 rounds; a hard cap of 1 would have left the unflagged-specs violation unresolved. A better rule: cap at 1 *content* fix-round, with an exception for CI-red/secrets regressions.

**Change 6 — Price claude-tier by tokens; split wall; count reviewer rounds: Sound, implementationally uneven.**
The AGENT_RUN_STATS emitter is homelab-side (not in this checkout), so I can't verify the exact code. The concept is correct and the report's own confidence split (High for ledger, Med for wall split) is honest. Pricing haiku/claude-tier from token counts requires the emitter to have access to token usage data from those providers — if that data isn't available through the current integration, this may require a provider-side change, not just an emitter change. The wall-time split into `queue_wait` vs `active_run` is the hardest part: it requires the harness to timestamp when a pod transitions from Pending→Running and from Running→Completed, and to distinguish dependency-wait from compute time. The report's confidence of "Med" on this split is appropriate.
