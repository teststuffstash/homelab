# oracle loop retro r4 — Claude Opus 5 (1M context)

## Summary (≤5 lines)
Every r3 process change merged within 4 days — but the ledger window ends 2026-08-11T17:00 and 5 of 6 merged that same afternoon, so **rounds/issue is unmovable from this data**; I scored them against live artifacts and trails instead, and found one half that never landed (`AGENT_INFEASIBLE` is absent from this repo's `.agents/fix.yaml`).
The dominant *un-addressed* cost is not model capability or review: it is **bookkeeping at the merge boundary** — the recipe mandates `Fixes #<issue>` unconditionally, so 3 of the ledger's 10 worst rows auto-closed or failed to close against their real delivered scope, each costing a corrective ride.
Second is **strike aggregation**: r3's fleet-level trigger was installed on the ci-red channel only, so 10 harness-death rounds across 4 error classes were still swapped model-by-model, one item at a time.
Third is that the pain rank itself is unsound — **5 of the 6 trailable `agent/blocked` rows are live-state `agent/done`**, so 62% of this retro's deep-dive budget went to work that had already converged.
Bucket-A falls on the strict reading (19 → 15) and rises on the wide one (25 → 31); jail $/day remains unmeasurable from this jail.

## Findings (ranked, ≤6)

*Ledger blind spots (`reviewer_rounds`, `wall_time_s`, `retry_storms`, `$0.00` = untracked) are taken as briefed and not re-derived; three further ones are named once in Evidence confidence.*

### F1 — The recipe mandates `Fixes #<issue>` unconditionally, so the closing keyword tracks the *dispatch*, not the *delivery*

**Evidence.** 3 of the ledger's 10 worst-ranked rows, across 3 repos:
- **oracle-fleet#225** (rank 7). The worker's own scoping comment at 16:13Z: *"This PR will not close #225 by itself"*, scoping to `ING-RT-FRESHNESS` only and explicitly excluding the rebuild, oracle-iac changes and the live delta run. PR#256 merged 18:30:50Z carrying `Fixes #225`; issue auto-closed 18:30:52Z; a merged-closeout ride reopened it 19:03:31Z (*"merged-closeout: outcome was WRONG — reopening"*). Still `OPEN`/`agent/blocked` today, 8 days on.
- **homelab#286** (rank 10). The dispatch comment scoped an acceptance leg out in advance (*"not deliverable in-pod … say plainly in the PR that the simulation is the post-merge leg"*). PR#294 merged 16:50:12Z → auto-closed → closeout ride reopened → human re-closed 17:10:33Z: *"Closed with the outcome VERIFIED this time (the closeout's reopen was correct)"*.
- **circles#19** (rank 4) is the mirror failure. PR#50 closed unmerged after the round-1 strike; the salvaged content merged via PR#51 with **no** `Fixes #19`, so the issue never closed — a goal-review ride closed it by hand at 2026-08-07T20:16:55Z, ~11.6 h after the code shipped (*"the code shipped, but the issue never closed"*).

**Mechanism (falsifiable).** `.agents/fix.yaml:85` reads `- PR body: `Fixes #{{ issue }}`, the red→green evidence, and the "Spec changes:" section.` — unconditional; `.agents/build.yaml:54` repeats it. The keyword is templated at PR-open from the dispatch, before the round knows its own delivered scope, and nothing reconciles trailer ⇄ acceptance at merge. Falsify by finding a merged PR that scoped an acceptance leg out, carried `Fixes #N`, and was *not* reopened.

**Process change.** One clause on `.agents/fix.yaml:85` (mirror on `.agents/build.yaml:54`): *"PR body: `Fixes #{{ issue }}` **only if this PR delivers every acceptance item in the issue**; if the round scoped any item out — including one the dispatch comment itself scoped out — write `Refs #{{ issue }}` plus one line naming what remains."* `.agents/` is CODEOWNERS-gated → propose in the PR, flagged.

**Expected saving.** 3 corrective coordinator rides + 2 human interventions in this window; kills an 11.6 h close latency (circles#19) and an 8-day-and-counting wrong issue state (oracle-fleet#225).

### F2 — Worker infra strikes have no fleet-level aggregation; r3's trigger was installed on the CI channel only

**Evidence.** 10 harness-death rounds over 9 of 40 rows (22.5%); in **9 of 9** the very next round exits `clean`. From the trails, they cluster hard:
- openrouter-operator: #14 `10:49:09Z model=deepseek/deepseek-v4-flash-0731 error_class=repetition_loop` ("eight consecutive ~max_tokens completions … no branch, no PR"), #14 `10:55:22Z mimo-v2.5 goose-32602-truncation`, #15 `12:34:13Z`, #17 `12:46:00Z`, #18 `13:03:50Z` — **5 strikes, 4 issues, 2 h 15 m, one day**, each triaged and swapped independently.
- circles: #22 `13:30:16Z` + `14:00:08Z` (Aug 5), #32 `12:00:49Z` (Aug 6), #19 `05:31:31Z` (Aug 7) — same class, same model, 3 issues, 3 days.
- Four distinct classes in the window: `goose-32602-truncation`, `repetition_loop`, `auth-storm` (sleep-tracking#96), and pace/token-expiry (oracle-fleet#1, two chain entries struck at 2917 s and 3918 s).

**Mechanism.** homelab#259 (merged 2026-08-11T12:49) added the third `agent/error` trigger to `agents/coordinator/README.md`, and its predicate — quoted in this brief's own excerpt — is *"the same failing step ruled environmental on ≥2 distinct PRs inside 24h"*, scoped to the **`ci-red` clause**. `AGENT_STRIKE` is a different channel; no predicate reads it, so N identical strikes remain N independent per-item model swaps. Note this survives homelab#256: that fix removes one class, not the aggregation gap.

**Process change.** Add the strike-side sibling to the *same* `agent/error` row in `agents/coordinator/README.md`, reusing #259's shape verbatim: when the same `error_class=` appears in `AGENT_STRIKE:` comments on ≥2 distinct issues inside 24 h, emit one `AGENT_ERROR: infra-class strike on N issues` instead of swapping the chain per item.

**Expected saving.** 3 of 4 openrouter-operator swaps and 2 of 3 circles swaps collapse to one signal — ~5 of 10 harness-death rounds, and the round-2 restarts they force (r3 measured "no resumable branch — nothing was committed" on 6 of 8).

### F3 — Retro changes land on the platform half and stall on the per-repo recipe half

**Evidence.** homelab#257 (r3 F4) closed `agent/done` 2026-08-11T15:04:14Z. Its body: *"`AGENT_INFEASIBLE: <path/resource>` as a first-class marker — recipe paragraph (this repo's `.agents/fix.yaml` first; other repos copy at their next recipe touch)"*. The scan half shipped **with** its ratchet — `agents/replay/fixtures/` now contains `c4c5-infeasible-parks`, `c4c5-infeasible-probe-fail`, `c4c5-infeasible-quoted-inert`. The recipe half did not: `grep -rn AGENT_INFEASIBLE` over this checkout returns **0 hits**, no oracle-fleet issue mentions it, and the "next recipe touch" demonstrably happened — commit `8bc4ecb` (2026-08-12T20:05:26, PR #259) edited `.agents/fix.yaml | 2 ++` for a different r3 item and did not carry it. Contrast: the two circles-side r3 changes were each filed as their own ride and both landed within a day (circles#77 `review-goal.md` §Maturity — verified present at line 37; circles#78 `build.yaml` incremental-WRITE — verified present at line 56).

**Mechanism.** A change with a platform half and a repo half is filed as one platform issue; the repo half is delegated to "the next recipe touch", which is not an owner. Every r3 change that got its own per-repo issue landed; the one that didn't, didn't.

**Process change.** File the open half now, as its own `agent-fix` issue against `.agents/fix.yaml`: add the `AGENT_INFEASIBLE: <path/resource>` paragraph beside the existing bullet at lines 83–84 (*"If the issue is not implementable as written (missing fact, contradiction), STOP, report exactly what's missing"*), which is the exact hook #257 named. Standing rule: a cross-repo retro change is filed as one issue **per repo**, never as a clause in another repo's issue body.

**Expected saving.** The scan side currently routes on a marker this stack's worker never emits — the platform half is inert for oracle-fleet. oracle-fleet#66 (rank 11) is the motivating class: 1 wasted round + 1 hand-override of `c4c5-redispatch`, still unguarded here.

### F4 — `models[]` is not round-ordered, so "failure class by model" is not computable from the ledger

**Evidence.** Two rows checked against trails, both contradict the positional read:
- openrouter-operator#14: ledger `models: ["tencent/hy3","xiaomi/mimo-v2.5"]`, exits `["harness-death","clean"]`. The trail's two round-1 strikes name `deepseek/deepseek-v4-flash-0731` and `xiaomi/mimo-v2.5` — a model that struck the run **does not appear in the row at all**, and the row's first model never struck.
- circles#17: ledger `models: ["deepseek/deepseek-v4-flash","tencent/hy3"]`; the round-1 report reads `AGENT_REPORT: deliberate stop (model=tencent/hy3, round=1 …)` — reverse order.

**Mechanism.** The emitter writes a de-duplicated *set* of models per issue rather than one per round, dropping strike-only entries and losing order. Any per-model failure table built from `zip(models, worker_exit_statuses)` — the obvious read, and the one the brief asks each retro to perform — is unsound.

**Process change.** In the ledger emitter (FU-058 brief-v2(b), already the open emitter issue this brief's blind-spot list names), emit `rounds: [{model, exit_status, error_class, ci}]` and derive `models[]` / `worker_exit_statuses[]` / `ci_sequence[]` from it — the same row that carries the missing `reviewer_rounds`.

**Expected saving.** No compute. Three consecutive retros have reconstructed model attribution by hand from trails; chain-ordering and strike decisions currently have no queryable evidence base.

### F5 — Five of the six trailable `agent/blocked` rows are live-state `agent/done`: the pain rank orders transient snapshots

**Evidence.** Ledger `terminal_label: agent/blocked` vs live state, checked today: oracle-fleet#1 → `CLOSED`/`agent/done` 2026-07-10T04:58:51Z (r3 found this one row); circles#17 → `CLOSED`/`agent/done`; circles#19 → `CLOSED`/`agent/done`; circles#57 → `CLOSED`/`agent/done`; homelab#270 → `CLOSED` (PR#275 merged 14:54:54Z — the row is stamped 15:00:38Z with `issue_state: CLOSED` **and** `terminal_label: agent/blocked`, i.e. self-contradictory in a single row). Only **oracle-fleet#225** is genuinely still blocked. The two sleep-tracking rows are untrailable.

**Mechanism.** The row is stamped at the emitting tick, and `terminal_label` is whatever label the issue wore at that instant — so a mid-flight park that a later ride cleared is indistinguishable from a real terminal block. r3 proved this for rank 1; it generalises to 5 of 6.

**Process change.** Same emitter (FU-058): re-stamp at the issue's terminal transition, or emit `snapshot: true` whenever `issue_state` is `OPEN` (or the label is non-terminal) at emit time, and exclude snapshot rows from the pain-rank key.

**Expected saving.** No compute — it stops the retro spending its own budget on converged work. 5 of 8 deep-dive slots (62%) this run; the deep-dive set is $1.4563 of the ledger's $4.6615.

## Proposed process changes

| change | artifact | expected saving | confidence |
|---|---|---|---|
| `Fixes #{{ issue }}` becomes conditional on delivering every acceptance item; otherwise `Refs #` + one line on what remains | `.agents/fix.yaml:85`; mirror `.agents/build.yaml:54` (CODEOWNERS-gated → flag in PR) | 3 corrective rides + 2 human interventions in-window; −11.6 h close latency (circles#19), −8 d wrong state (oracle-fleet#225) | **High** — mechanism is one literal line; 3 independent instances in 3 repos |
| Strike-side sibling to the `agent/error` fleet trigger: same `error_class=` on ≥2 issues in 24 h → one `AGENT_ERROR`, not N chain swaps | `agents/coordinator/README.md`, the `agent/error` state-machine row (extends homelab#259's shape) | ~5 of 10 harness-death rounds + their round-2 restarts | Med-High — the shape is already installed for ci-red; the ≥2/24h threshold is inherited, not measured |
| File the missing recipe half: `AGENT_INFEASIBLE: <path/resource>` paragraph beside the "not implementable as written" bullet | `.agents/fix.yaml:83-84` (as homelab#257's body specified) | makes an already-merged, currently-inert scan half live for this stack; oracle-fleet#66's class (1 round + 1 hand-override) | **High** — absence verified by grep; scan half + 3 replay fixtures already shipped |
| Standing rule: a cross-repo retro change is filed as one issue **per repo**, never delegated to "the next recipe touch" | retro filing procedure (evidence: circles#77/#78 landed, homelab#257's repo half did not) | 1 of 6 r3 changes silently half-landed | Med — n=1 miss vs n=2 hits, but the causal contrast is clean |
| Emitter: `rounds: [{model, exit_status, error_class, ci}]` as the source of truth; derive the flat arrays from it | ledger emitter, FU-058 brief-v2(b) | no compute; unblocks the model-routing analysis every retro is asked for and none can do | **High** — two rows verified contradictory; same row also carries `reviewer_rounds` |
| Emitter: `snapshot: true` when the row is stamped mid-flight; drop snapshot rows from the pain-rank key | ledger emitter, FU-058 brief-v2(b) | 62% of the deep-dive budget this run | **High** — 5 of 6 verified; homelab#270's row is internally contradictory |

## Task granularity (per deep-dive task)

| # | task | verdict | evidence |
|---|---|---|---|
| 1 | oracle-fleet#1 | **chunked-right** — the cure was policy, not decomposition | 5 infra deaths (3 classes) + 3 logic rounds; zero cross-chunk friction — every burned round is infra or a *new* reviewer finding on the same diff. The one split that helped happened at arbitration, not authoring: residuals filed as #7/#8 with their own round budgets. |
| 2 | sleep-tracking#71 | **unverifiable** | `teststuffstash/sleep-tracking` not resolvable with this token. Ledger only: 3 rounds `failed`/`failed`/`blocked-deliberate`, 3 models, worst calibration in the set (0.544), `active_run_s` 11,733 > `wall_time_s` 10,055. |
| 3 | circles#17 | **should-have-been-fan-out** — and the loop diagnosed itself | r1 stopped deliberately mid spec-analysis, `built: false`, no code. The goal-decompose comment names the cause verbatim: *"circles#17 r1 died from importing the whole contract into one ride's context"*, then split on the scope's own DATA/RENDER seam into two single-ride children (#22/#23), both of which converged and met the goal 2026-08-05T18:15. |
| 4 | circles#19 | **chunked-right** — 100% of burned rounds environmental | One deliverable (the kind gate); the whole loop is a corrupt registry blob (`short read: expected 3642247 bytes but got 0`) re-diagnosed across PRs #50/#51 with 3 human interventions. **New datum:** the ledger says `rounds: 2` while the trail reaches *"round 5"* — rounds are undercounted when work migrates to a successor PR (branch changed, issue didn't). |
| 5 | homelab#270 | **chunked-right — the model run of the set** | Explicitly scoped as *"the half PR #267 deliberately left unshipped, so it completes that finding rather than widening it"*. 2 clean rounds, CI green both, PR#275 open 14:11:56 → merged 14:54:54 (**43 min**), reviewer + human same hour. See Wins. |
| 6 | circles#57 | **chunked-right, and it IS the integration-rework receipt** | Exists only because #29's assembly review found bake was never wired into the real image — a seam between the bake children and the page/image child that no child owned; 4 rounds. **New datum on the price of fan-out:** round 2 was refused at pre-flight by the goal-budget gate (Σ child caps $26 > the goal's `Budget: $12`) — not rework, but a fan-out-caused stall costing ~4.5 h (refusal 2026-08-07T22:15 → requeue 2026-08-08T02:52 after an operator ruling). |
| 7 | oracle-fleet#225 | **chunked-wrong — too coarse, mixed lanes** | Scope bundled in-repo code (`ING-RT-FRESHNESS`) + an attended rebuild + oracle-iac#322's CronWorkflow + a live delta run. The worker split it itself at 16:13Z (*"none of that is executable by a fix-class worker"*), shipped the one in-repo half, and the unconditional `Fixes #225` then mis-closed the parent (F1). Should have been two issues at authoring. |
| 8 | sleep-tracking#43 | **unverifiable** | Repo inaccessible. Ledger only: 1 round, exit `no-artifact`, `ci_sequence:[true]`, closed 2026-07-29T05:21:58Z, calibration_error 0.048. |

## Wins to codify

1. **"Complete the prior finding's unshipped half — don't widen it."** homelab#270 (rank 5) is the fastest clean run in the deep-dive set and its dispatch comment states the scoping rule outright: *"Parent #248 is merged/done — this is the half PR #267 deliberately left unshipped, so it completes that finding rather than widening it."* Result: 2 clean rounds, CI green both, 43-minute PR lifetime, reviewer + human approval inside the hour. The exact inverse is rank 7 (oracle-fleet#225: four lanes in one issue, zero acceptance items met, reopened, still open). Codify as one line in the coordinator brief's dispatch play: *an issue that continues a merged finding names the specific unshipped half in its scope line; if the round needs more than that half, file a sibling instead of widening.*
2. **Salvage claims are verified, not asserted.** circles#19 burned a full human round-trip on three contradictory readings of one branch: the strike said *"Resumable branch pushed: `agent/20260807-050449`"*; the operator's re-queue said *"nothing committed and no branch created (verified against the branch list, not assumed)"*; round 2 then resumed from it successfully with 296 lines of `scripts/test-system.sh`. The winning method is in round 2's own words — *"verified directly against the branch, which exists and merge-bases cleanly"*. Codify into the C5 resume step: the `AGENT_STRIKE:` comment carries the branch sha + commit count from `git rev-parse`/`git rev-list --count`, and the resuming ride quotes it rather than re-deriving.
3. **Already codified, not yet exercised — name it so it doesn't get re-proposed.** r3's Win-1 landed here as `.agents/fix.yaml:39-40` (*"A reviewer's blocking finding is a row: commit it RED first, then fix — so re-review verifies an executable pin, not a claim"*), commit `8bc4ecb`, 2026-08-12. Zero oracle-fleet rides have run against it since, so it is codified and unscored.

## Platform KPIs (ADR-103)

**(1) Bucket-A — 15 events (strict), window 2026-08-10 → 2026-08-17.** Same rule as r3 (coordinator / review-reflex / prompt-launcher / scan defects filed as platform-repo issues; excluding pure infra, feature build-out, docs-drift-only). Counted from platform-repo issues only — I have no responder-ledger access.
- *scan* (3): homelab#397 (doorbell fast-path bypasses `WORKER_AUTHOR` scope), #405 (`agent-fix` without an `agent/*` state is invisible to every scan class), #309 (no pre-dispatch `Touches:`⇄GUARDED check — burned a round)
- *coordinator* (3): #367 (goal budget gate reads the DIRECT parent → every post-launch bucket child ungated), #361 (refusal comment dedupes against the LAST comment only), #377 (`jq -e` fail-closed guards are fail-OPEN in the coordinator image)
- *prompt/launcher* (4): #242 (128 KiB `MAX_ARG_STRLEN` silent pre-pod cliff), #369 (FU-042 pre-flight refuses on a `#N` *mention*), #388 (CODEOWNERS has no `.agents/` entry), #277 (brief drift: infeasible-terminal banner still says "NOT yet installed anywhere")
- *review reflex / belts* (3): #428 (`AgentErrorFlagged` — PR #419 carries an unrelated live-cluster commit), #379 (ADR-097 escaped-diff belt not firing: 3 of the last 12 merges), #354 (`agents/**` MAY-AUTHOR rationale false for CI-executed fixtures)
- *loop-state misclassification* (2): #314 (`blocked-deliberate` counted as an infra death), #235 (`AgentRunInfraDeathBurst` trips on model-scout canaries)

Variants, reported rather than chosen: **+6 retro lane** (#237 `RetroReportOverdue`, #248, #268, #269, #270, #292) → 21; **+10 responder / fix-debounce lane** (#238, #239, #244, #245, #249, #252, #253, #272, #360, #450) → **31**, the figure comparable to r3's wide 25.

**(2) Jail $/day — NOT MEASURED.** `sum(increase(claude_code_cost_usage_USD_total{stack="jail"}[7d]))/7` is unrunnable here: `kubectl` authenticates as `system:serviceaccount:oracle-fleet:agentstack-worker` and is namespace-scoped (`services is forbidden … at the cluster scope`, `namespaces is forbidden …`), and no Prometheus/Thanos endpoint is reachable. I did **not** substitute a ledger figure: the ledger's $4.6615 over 40 rows (8 rows at $0.00 = UNTRACKED) spans 34 days of API-rail spend and is a different quantity.

**(3) Trend — strict falls, wide rises, share falls on both.** Strict bucket-A **19 → 15 (−21%)** vs r3's 2026-08-04→08-11 window; wide **25 → 31 (+24%)**. Total platform issue volume rose 75 → 106 (+41%), so as a share of filings both readings fall: 25% → 14% strict, 33% → 29% wide. The fall is concentrated exactly where replay gates landed — r3's window carried four `AgentCoordinateScanWedged` firing events; this week carries **zero**. The rise is concentrated in the fix-debounce/responder lane, which was largely *built* during this window, so its defect density is first-pass, not regression. Caveat: the two windows overlap on 2026-08-11 (r3 counted through ~#238, filed ~09:26Z); excluding the overlap day the strict count is 13.

**(4) Proposed next gate — `agents/replay/fixtures/lane-membership-quoted-inert/`.** Highest-recurrence unguarded class this week is **lane membership decided by an unanchored substring match**: #249 (fix-debounce's alert-lane test — a non-alert issue that *quotes* an alert name joins the lane), #272 (meta-needs-attention's alert-lane exclusion, same defect, different predicate), #450 (the 🌱 triage class has no carve-out for Renovate's Dependency Dashboard) — 3 events, 3 predicates, one shape, with the pending-set-incompleteness siblings #238/#244/#253 adjacent. The fixture shape is already proven in-tree: `c4c5-infeasible-quoted-inert` guards exactly this for the `AGENT_INFEASIBLE:` marker; no sibling exists for the lane predicates. Recorded world = one issue whose *body* quotes an alertname inside a fence and one whose *title* quotes the 🌱 marker; expected actions = no lane membership, no re-queue, no dispatch, for both. `scripts/merge-path-lint.py`'s ADR-103 orphan gate supplies the ratchet.

## Predecessor score

**All six r3 changes merged — five of them inside 4 h 30 m on 2026-08-11 — and the ledger cannot score any of them.** Landing evidence: homelab#258 (`BUFFER` 1.5→2.0) 11:47:21Z; #256 (`GOOSE_MAX_TOKENS=16384` on the worker goose arm) 12:35:26Z; #259 (fleet ci-red trigger + arbitrate-quotes-the-edit) 12:49:49Z; #257 (`AGENT_INFEASIBLE` terminal) 15:04:14Z; circles#77 (§Maturity → `review-goal.md`) and circles#78 (incremental-WRITE → `build.yaml`) both 2026-08-12 — I verified the last two directly in circles' `.agents/` (`review-goal.md:37`, `build.yaml:56`), and r3's F5 is visible in this brief's own `estimate_budget.py` excerpt.

**Rounds/issue: unmovable, not unchanged.** The r4 ledger is the same 40-row window as r3's (last row 2026-08-11T17:00:25Z). At most two rows postdate any change — homelab#270 (15:00) and homelab#286 (17:00), both haiku platform rides, both 1–2 clean rounds. Any KPI delta here would be noise, so I claim none.

**Out-of-ledger score, honestly confounded.** Zero `goose-32602-truncation` strikes and zero `AGENT_STRIKE` comments anywhere after 2026-08-07 (searched all four repos for issues updated ≥2026-08-12). But the class had already gone quiet **four days before its cure merged**, and stack ride volume since is near zero — oracle-fleet has closed exactly one issue since 08-11 (#258, the r3 Win-1 codification), circles two (the r3 port issues). r3's F1 is therefore **unfalsified and uncredited**; it needs a week of real ride volume.

**One half did not land** — r3 F4's recipe paragraph, delegated to "the next recipe touch" and missed by that very touch (F3 above). **One change did not land at all**: r3's F6 (rename `wall_time_s` → `pr_open_to_terminal_s`, drop it from the rank key) — this brief's blind-spot list still describes the field as-is and the pain rank is still wall-driven, which is why F5 was still worth finding.

## Evidence confidence

- **Two of eight deep-dive tasks have no trail.** `teststuffstash/sleep-tracking` is not resolvable with this token (`Could not resolve to a Repository`) — ranks 2 (#71) and 8 (#43) are ledger-only, as they were for r3.
- **Jail $/day is unmeasured, not estimated** — cluster RBAC blocks it (exact errors quoted in KPI 2). No ledger figure was substituted.
- **Bucket-A is platform-repo issues only.** ADR-103 says "responder ledger + platform-repo issues"; I have no responder-ledger access, so the count is a lower bound, and the strict/wide split is a classification judgment I state rather than resolve.
- **F4 is verified on two rows, not all forty.** openrouter-operator#14 and circles#17 both contradict the positional read of `models[]`; I did not open every strike comment. The claim is "positional attribution is unreliable", not "always reversed".
- **F2's ≥2-in-24h threshold is inherited from homelab#259's shape, not measured optimal** — the evidence supports "strikes have no cross-item memory", not that 2 is the right number.
- **Three further ledger blind spots beyond the four briefed** (r3 found the first): (a) *snapshot rows* — 5 of 6 trailable `agent/blocked` rows are live-state done, and homelab#270's row carries `issue_state: CLOSED` with `terminal_label: agent/blocked` simultaneously; (b) *`models[]` is not round-ordered* (F4); (c) *`rounds` undercounts across a successor PR* — circles#19 reads `rounds: 2` while its trail reaches "round 5" on PR#51.
- **`active_run_s` exceeds `wall_time_s` on four rows** (sleep-tracking#71 11,733 > 10,055; sleep-tracking#96 13,314 > 6,500; circles#19 3,535 > 2,519; circles#57 3,514 with `wall_time_s: 0`), so `active_run_s` appears to sum strike rides that fall outside the wall window. I used it for ratios only, never as a duration.
- **Calibration-by-tier and retry-storm clustering were examined and deliberately not raised as findings.** r3's `BUFFER` 2.0 merged 2026-08-11T11:47 and **0 of the 8 calibrated rows postdate it**, so the tier spread (sm 0.544 / xs 0.259 / lg mean 0.169 / md 0.048) carries no new information. `retry_storms` shows 1 event in 40 rows while trails show at least two uncounted model-level loops (openrouter-operator#14 `repetition_loop`, sleep-tracking#96's auth-storm at 13,314 s active for $0.0001) — the field cannot support clustering analysis at all, which is the briefed blind spot rather than a finding.
- **I did not exec into any pod**, so mechanism claims are static: verified by grep over this checkout, by the GitHub contents API for sibling repos, and by trail quotations.
