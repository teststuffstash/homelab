# platform loop retro r2 — Claude Opus 5 (1M context)

## Summary (≤5 lines)
The loop's biggest repeat cost this window is not model capability or review depth — it is **diagnosed defects that never become dispatchable work**: 16 of 22 open `agent-fix` issues carry no `agent/*` state, 7 of them loop-filed control-path defects (29.1 issue-days idle), and two of those classes charged **15 coordinator arbitrate/ci-red rides across PR#1003/#1030/#1058** and parked `homelab#1041` two hours after the loop itself filed the cause (#1060).
Review rework has one dominant *new* shape: 6 of 31 post-window blocking verdicts are **narrowing regressions** — a replacement predicate/filter that covers fewer input cases than the code it replaced (#995 → refiled as #998 → PR#1072).
Infra strikes cost 35 of 137 worker attempts (67% of tasks lost their first attempt); the model-swap protocol works on homelab (deepseek/opencode-go → haiku, clean) and visibly does **not** on oracle-fleet, where 5 identical `(deepseek-v4-flash, repetition-loop)` rides on `oracle-fleet#304` burned 13,165s of active run for zero artifact.
Two one-line ledger defects corrupt this very report's input: `is_snapshot` compares `issue_state == "open"` against an emitted `"OPEN"` (all 13 OPEN rows unflagged, **all 8 deep-dive slots**), and 12 of 17 homelab issues wearing `agent/blocked` are closed — 4 with merged PRs.
Ledger blind spots (`reviewer_rounds`, undecomposed `wall_time_s`, harness-only `retry_storms`, `$0.00` = untracked) are taken as briefed and not re-derived; review rounds are counted from PR verdicts throughout.

## Findings (ranked, ≤6)

### F1 — The loop files its own control-path defects as bare `agent-fix`, which no scan class reads, so the defect keeps charging rides

**Evidence.** 16 of 22 open `agent-fix` issues in `teststuffstash/homelab` carry **no `agent/*` state label** (median age 4.4d, max 19.6d). Seven are defects the loop filed against its own control path, all authored by `app/homelab-agents-1234`, all bare `agent-fix`: `#1060` (0.4d), `#1028` (0.7d), `#1006` (4.3d), `#994` (4.4d), `#975` (4.5d), `#828`/`#829` (7.4d) — **29.1 issue-days** of zero motion. The cost is measurable in the same window:
- `#1060` ("the issue-keyed round ceiling counts sibling PRs that merely MENTION the issue") was filed **2026-08-30T20:04Z**. At **22:07Z the same night**, the arbitration ruling on PR#1058 parked `homelab#1041` (rank 3) citing exactly that arithmetic: *"4 fix rounds counted on issue #1041 (2 PRs) … cap 3"*.
- `#1011` (seat-filed 08-27, same sink) names the arbitrate `state-fp` churn after PR#1003 drew 3 rides in 8m35s. Un-queued, the class then recurred twice: PR#1030 (4 dispatch markers, logged as a second witness in the issue itself on 08-30) and **PR#1058: 8 `arbitrate` dispatch markers between 19:55Z and 20:43Z** (three of them at 20:39/20:41/20:43, no intervening head change; two byte-identical rulings at the same head `75e2a9c8`, 19:52Z and 20:02Z). **15 coordinator rides, 3 distinct rulings.**

**Mechanism (falsifiable).** The r1-F1 clause now merged on the `agent/error` row mandates the pair — *"opens ONE `agent-fix` + `agent/queued` issue"* — but only for a **fleet** ruling. Ordinary self-filed control-path defects have no such requirement, and `homelab#405` established the state has no reader (dispatch = `agent-fix` ∧ `agent/queued`, `coordinator-scan.sh:757`). #405 was closed with an operator ruling that bare `agent-fix` is *ordinary backlog* for **human** filings — which is right, and is exactly why the loop's own filings need the second label instead of an auto-queue-everything sweep. Falsify by finding a bare-`agent-fix` issue that the scan dispatched on its own.

**Process change.** One clause appended to the same STRIKE-channel sibling on the `agent/error` row of `agents/coordinator/README.md` that already carries the r1-F1 sentence: *a defect the loop files against its own control path (scan, coordinator, reflex, launcher, ledger) carries `agent-fix` + `agent/queued`, the same pair a fleet ruling files — a human's `agent-fix` filing stays backlog (#405 ruling), the loop's own diagnosis is ready by construction.* Lane capacity and WIP remain the scan's job (ADR-094), so this cannot flood the lane.

**Expected saving.** The 12 post-filing arbitrate rides on PR#1030 + PR#1058 (each an opus coordinator session), and ~2h of head start for `#1060` before the park it caused — r1 measured a comparable one-line scan fix at 1h09m file→merge (`#629`→PR#643). Standing backlog latency drops from 29.1 issue-days to one scan tick.

---

### F2 — Six of 31 blocking verdicts are narrowing regressions: the replacement predicate accepts fewer cases than the code it replaced

**Evidence.** Post-window blocking verdicts on merged agent PRs, all shipped CI-green:
- PR#942 r1 — the new `IS_HARNESS_DEATH` gate *"silently narrows strike emission to `harness-death|auth-storm|timeout|quota|budget-*`"*; every other classified error stops striking.
- PR#943 — *"the pre-existing `continue` … was removed and replaced with only a comment … this makes master worse."*
- PR#995 — the rewritten `PF_LIVE` jq filter *"silently drops pods in phase `Unknown`"* that the old `phase!=Succeeded,phase!=Failed` field-selector counted. **This one recurred**: the same rewrite also dropped `.status.phase`-absent pods, refiled as `#998` and repaired by PR#1072.
- PR#996 — `idem_tag` assigned only under `if [ "$SHADOW" -eq 0 ]` but referenced unconditionally: *"the fix crashes shadow mode outright."*
- PR#997 — the `eval_time` change *"silently drops all test coverage of the alert's actual pro-rated formula."*
- PR#1014 r1 — the new detector *"has a 24h blind spot on the exact incident class this alert exists for."*

**Mechanism.** r1-F4's sibling-site line landed in `.agents/fix.yaml:112` (2026-08-30T20:23Z) and asks the author to enumerate *sibling sites of the changed predicate* — a **forward** sweep. None of the six above has a sibling-site problem; each is a **backward** one: the old predicate's accepted-input set is never stated, so nothing compares it to the new one. Falsify by finding a merged PR whose body enumerates the pre-fix accepted cases and still shipped a dropped case.

**Process change.** One line in `.agents/fix.yaml`'s PR-body requirements block, directly beside r1-F4's sibling-site line at `:112`: *"If the diff REPLACES an existing predicate, filter, selector or gate, the PR body lists the input cases the old one accepted and states, case by case, which the new one still accepts."*

**Expected saving.** 6 of 31 blocking rounds (19%) per window — each a worker round plus a reviewer ride. On the one that escaped review entirely (#995), the repair cost an extra issue (`#998`), an extra PR (#1072) and two more approvals to restore parity.

---

### F3 — The strike protocol swaps models on homelab and repeats the same one on oracle-fleet: 5 identical rides for zero artifact

**Evidence.** 137 worker attempts across 33 structured rows; 44 non-clean, of which **35 are infra strikes** (`harness-death` 11, `auth-storm` 11, `failed` 9, `budget-403` 4). 22 of 33 tasks (67%) lost their first attempt. The swap behaviour splits cleanly by stack:
- **Works (homelab):** `#913`, `#625`, `#866`, `#617`, `#648`, `#622`, `#629`, `#779`, `#892` — one strike on `opencode-go/deepseek-v4-flash` or `deepseek-v4-flash`, immediate swap to `haiku`, clean. All 5 `nonzero-exit-1` events on `opencode-go/deepseek-v4-flash` are one strike each.
- **Does not (oracle-fleet):** `oracle-fleet#304` — **5 consecutive `(deepseek/deepseek-v4-flash, repetition-loop)` harness deaths**, 13,165s `active_run_s`, no PR, no artifact, terminal `agent/blocked`. `#278` 3× and `#279` 3× identical `(deepseek-v4-flash, http-401-storm)`. All 11 `http-401-storm` and all 5 `repetition-loop` events in the ledger are that one `(project, model)` pair.
- The fleet channel *did* fire: `homelab#1004` ("recurring 401 auth-storm circuit-trips on oracle-fleet dispatches (3x in ~3h)") was filed and closed `agent/done` on 08-26 — and then **10 of the 11 storms landed on 08-30**, with `#1093` reopening the class on 08-31.

**Mechanism.** The invariants line in `agents/coordinator/README.md` says infra failures are *"strikes that swap the model instead of consuming a round"*. Nothing bounds a strike that swaps to the *same* `(model, error_class)` pair, so a stack whose pool has no live alternative re-rides the identical failure at full pod cost. Falsify by finding an oracle-fleet row where a repeated strike swapped to a different model.

**Process change.** One clause on the same invariants line in `agents/coordinator/README.md`: *a second strike with the identical `(model, error_class)` pair on one issue is not a swap — it routes to the `agent/error` STRIKE-channel path (label + one `AGENT_ERROR:` comment + the one filed issue) instead of another ride.* This reuses the merged r1-F1 filing clause verbatim; it adds only the same-issue repeat trigger next to the existing ≥2-distinct-issues one.

**Expected saving.** 3 of 5 rides on `oracle-fleet#304` (≈7,900s of its 13,165s active run, at $0-untracked cost) plus ~5 of the 11 auth-storm rides; ~8 pod spin-ups for guaranteed failures per window at the observed rate.

---

### F4 — `is_snapshot` compares `"open"` against an emitted `"OPEN"`, so every mid-flight row is ranked as a terminal fact — including all 8 deep-dive slots

**Evidence.** `agents/ledger.py:192` returns `issue_state == "open" or terminal_label not in TERMINAL_LABELS`, while `:376` emits `issue_state` uppercase (`{"OPEN","CLOSED"}` are the only two values in all 40 rows). **Zero rows carry a `snapshot` field; 13 rows are `OPEN`; ranks 1–8 are `OPEN` without exception.** The clearest instance is rank 3: `homelab#1041`'s row is stamped `2026-08-30T22:30:41Z` — 40 min after PR#1058's last commit (21:50Z) and 23 min after the arbitration ruling — and PR#1058 is **still open** at retro time with 4 reviews and no merge. The docstring at `:188` states the intent plainly: *"a row stamped mid-flight is a snapshot, not a terminal fact … the retro's pain-rank excludes these."*

**Mechanism.** A case-sensitivity slip makes r4-F5's guard inert for the OPEN half of its predicate; the `agent/blocked`-half still passes because `agent/blocked` is in `TERMINAL_LABELS`. Falsify by finding any emitted row with `"issue_state":"open"` or a `snapshot` field.

**Process change.** One character-level fix at `agents/ledger.py:192`: compare `str(issue_state).lower() == "open"`.

**Expected saving.** No compute. It restores r4-F5's intended exclusion: at this window's data it removes 13 of 40 rows from pain-rank eligibility and would have freed **at least 3 of this run's 8 deep-dive slots** (`#1041` in flight, plus `#913`/`#625`, see F5) for tasks that actually terminated badly.

---

### F5 — 12 of 17 issues wearing `agent/blocked` are closed, and 4 of those merged: the pain-rank's terminal label is a stale label, not an outcome

**Evidence.** Live label state in `teststuffstash/homelab`: 5 open + 12 closed issues carry `agent/blocked`. Four of the closed ones shipped: `#913` (PR#915 **merged** 2026-08-26T16:50Z, 14 reviews, ending in two APPROVED), `#625` (PR#631 merged), `#270` (PR#275 merged), `#148` (PR#150 merged). Three others (`#375`, `#329`, `#292`) are legitimate human parks — I read all three, and their bodies/comments are pre-dispatch refusals (structurally unreachable deliverable; goal-budget gate; seat disposition), so the label is correct there. The ledger derives `terminal_label` from the label, so `#913` and `#625` entered this retro's deep-dive set at **ranks 1 and 5** as failures while both are merged work.

**Mechanism.** The `agent/done` row of `agents/coordinator/README.md` reads *"merged | coordinator"* — a single writer, no reconciler. Its two siblings both got one this month (`agent/in-progress` via IL-T16/#155, `agent/review` via r1-F5/#928), so the merged-terminal is the only state with no level-triggered repair. Falsify by finding a closed issue whose merged PR mentions it and whose label the scan corrected on its own.

**Process change.** Extend the same phantom-reconciler sentence to the `agent/done` row of `agents/coordinator/README.md`, verbatim shape: *a closed issue with a merged PR mentioning it, still labelled `agent/blocked` or `agent/review` past `C4C5_PERSIST_S`, gets `agent/done`.*

**Expected saving.** 2 of 8 deep-dive slots in this run alone (ranks 1 and 5), 4 mis-classified terminal rows in the ledger, and a pain-rank ordering that reflects outcomes rather than label debt.

---

### F6 — `calibration_error` is cumulative task spend ÷ one round's per-session cap, so it crosses 1.0 by round count rather than by mis-sizing

**Evidence.** `agents/ledger.py:378` computes `round(summ["total_cost_usd"] / cap, 3)`, where `cap` comes from `_budget_from_cr` — a single OpenRouterKey CR for the issue (PR#1065 made it "pick highest round number deterministically"). The numerator is the whole task, the denominator one session. The two rows above 1.0 are both multi-round: `homelab#1041` (5 rounds, $0.5245 vs `sm` $0.50 → 1.049) and `oracle-fleet#284` (4 rounds, $0.2614 vs `xs` $0.25 → 1.046). **No round of `homelab#1041` hit a `budget-403`** — every session stayed inside its own cap; only the sum did not. Normalised per round, the spread collapses: $0.21/round (`#1041`), $0.26 (`#284`), $0.18 (`sleep#71`) at xs/sm vs $0.037 (`circles#32`), $0.034 (`circles#19`) at lg — a real 5× per-round difference that the raw field hides behind the round-count effect.

**Mechanism.** The field name promises calibration but the arithmetic measures utilisation-of-one-cap-by-many-sessions, so it is monotone in rounds. Falsify by finding a row >1.0 whose rounds all stayed under cap yet 403'd.

**Process change.** In `agents/ledger.py:378`, divide by the number of capped rounds (`total_cost_usd / (cap * len(rounds))`) — or emit that alongside as the calibration figure — so the number the retro reads is per-session utilisation.

**Expected saving.** No compute. It is the precondition for scoring r3-F5's `1.5 → 2.0` headroom on the stacks where the 403s happen: with r1-F6 now landed, 4 new tiered rows exist (`homelab#1041`, `oracle-fleet#279/#283/#284`) and today two of them read "over cap" when no session was.

## Proposed process changes

| change | artifact | expected saving | confidence |
|---|---|---|---|
| A control-path defect the **loop itself** files carries `agent-fix` + `agent/queued` — the same pair the fleet-ruling clause already mandates; a human's bare `agent-fix` stays backlog per the #405 ruling | `agents/coordinator/README.md`, STRIKE-channel sibling clause on the `agent/error` row | 12 post-filing arbitrate rides (PR#1030, PR#1058); ~2h head start for `#1060` before the `#1041` park; 29.1 issue-days of standing latency | **High** — 7 loop-filed instances, and one same-night cause→cost pair (#1060 20:04Z → park 22:07Z) |
| If the diff REPLACES a predicate/filter/selector/gate, the PR body lists the input cases the old one accepted and which the new one still accepts | `.agents/fix.yaml`, PR-body requirements block, beside the r1-F4 sibling-site line (`:112`) | 6 of 31 blocking rounds (19%); the #995→#998→PR#1072 repair chain (1 issue + 1 PR + 2 approvals) | **High** — 6 independent instances across 6 PRs in one window, one with a documented recurrence |
| A second strike with the identical `(model, error_class)` pair on one issue is not a swap — route it to the existing `agent/error` STRIKE-channel path instead of another ride | `agents/coordinator/README.md`, the bounded-rounds/MODEL invariants line | 3 of 5 rides on `oracle-fleet#304` (~7,900s active), ~5 of 11 auth-storm rides | Med-High — clean stack-vs-stack contrast (homelab swaps and goes clean; oracle repeats), but oracle trails are unreachable |
| `is_snapshot`: compare `issue_state.lower() == "open"` | `agents/ledger.py:192` | 13 of 40 rows excluded from pain-rank as designed; ≥3 of 8 deep-dive slots freed | **High** — the emitted values are uppercase in all 40 rows and 0 rows carry `snapshot` |
| Extend the IL-T16 phantom-reconciler shape to the `agent/done` row: closed issue + merged PR mentioning it + stale `agent/blocked`/`agent/review` past `C4C5_PERSIST_S` → `agent/done` | `agents/coordinator/README.md`, `agent/done` state-machine row | 4 mis-labelled terminal rows; 2 of 8 deep-dive slots this run | Med-High — the identical shape is already installed and proven on both sibling states |
| `calibration_error` divides by `cap × rounds` (per-session utilisation), not by one round's cap | `agents/ledger.py:378` | no compute; makes r3-F5's ×2.0 headroom scoreable on the 4 newly-tiered rows | **High** — arithmetic verified against all 8 tiered rows (`spend/cap` reproduces every value) |

**No issues were filed by this session.** Per the output contract the intended parents are: F3 → `oracle-fleet#304` (origin row; filed in the platform repo since that repo is unreachable from this pod). F1, F2, F4, F5, F6 → standalone-honest (each aggregates 4–16 rows or issues across ≥3 PRs). Never the retro report.

## Task granularity (per deep-dive task)

| # | task | verdict | evidence |
|---|---|---|---|
| 1 | `homelab#913` | **chunked-right; the round bound, not the scope, is what leaked** | One deliverable (`item_class_push` call sites: batch-per-tick + first-transition timestamps). 7 logic rounds and 7 `CHANGES_REQUESTED` (5 reviewer, 2 human codeowner under ADR-110) — **every one an in-diff defect of this PR's own fix**: a `set -euo pipefail` crash in `item_class_flush`, a half-landed `$qdeps` fix, then the flush hoist colliding with the FU-146 retry loop *inside* the same stacks loop. Zero cross-chunk friction; residue was correctly split to `#968` rather than absorbed. 81 commits, **59 of them (73%) `Merge branch`** — updater churn, not work. PR merged; the row is only in this set because of F5. |
| 2 | `sleep-tracking#123` | **unverifiable** | `teststuffstash/sleep-tracking` 404s under both tokens. Ledger only: 6 attempts on 3 models, 2 `goose-32602-truncation` harness deaths, clean at rounds 1–2 then `ci-red` at rounds 3 and 4, `wall_time_s` 1,088,595 (302h) against 10,062s active. |
| 3 | `homelab#1041` | **chunked-right; parked by accounting, not by scope** | Explicitly *"acceptance item 2 only"* of goal `#1039`, with a native blocked-by on `#1040` (*"the launcher reads the knob that child defines"*). All 5 rounds worker-clean and CI-green; the 3 blocking verdicts are in-chunk heredoc/MCP plumbing inside `agents/reviewer-session.sh`, each round's fix introducing the next round's regression until round 5 built `MCP_PREP` at launcher level. The park came from the **issue-keyed ceiling counting two sibling PRs** (`#1060`), not from cross-chunk rework. Still open and in flight at retro time (F4). |
| 4 | `oracle-fleet#304` | **unverifiable, and not a granularity question** | Repo 404s. Ledger only: 5 identical `repetition-loop` harness deaths on one model, `ci_sequence` all null, no PR, 13,165s active. The task never reached code, so no chunking decision was ever exercised. |
| 5 | `homelab#625` | **chunked-right** (agrees with r1) | One deliverable (absorb exit-3 racing refusals in dispatch). PR#631 open→merge **1h56m**, 2 blocking verdicts, both in-diff defects of its own fix (`grep -m1` never draining past the first same-clause match; then a new `while` repointing an existing `continue`), then APPROVED. The one wasted attempt is an `opencode-go` rail strike, not scope. PR merged — in this set only via F5. |
| 6 | `oracle-fleet#1` | **unverifiable** | Repo 404s. Ledger only, legacy integer `rounds` shape: 4 attempts, exit statuses `"0"`, `wall_time_s` 13,762, $0.248, no `queue_wait_s`/`active_run_s`. r4 judged it chunked-right; no new evidence either way. |
| 7 | `sleep-tracking#71` | **unverifiable** | Repo 404s. Ledger only: 3 attempts on 3 *different* models (`ling-3.0-flash:free` → `laguna-s-2.1` → `hy3`), `failed`/`failed`/`blocked-deliberate`, no PR, `active_run_s` 11,733 > `wall_time_s` 10,055. |
| 8 | `homelab#778` | **should-have-been-one** (r1's verdict stands; new datum) | r1 documented the 4-arm fan-out pilot: 4 pods in 4 seconds, 3 permanently `Unschedulable`, lane wedged, one arm survived, PR#790 closed with its deliverable returned *"via the NORMAL worker flow"*. New this run: PR#790 has **zero reviews** and the issue has been untouched since 2026-08-25T18:19Z (6 days) at `agent/blocked` — a human gate, so r1-F5's `agent/review` reconciler (merged 08-26) correctly cannot reach it. |

**Fan-out judgement:** no task in this window warranted a subagent fan-out; the only fan-out in the corpus (`#778`) cost a wedged lane and three re-queued arms for one surviving PR.

## Wins to codify

1. **State the pre-fix behaviour as a case table and build the pin so it fails against pre-fix source.** The two cleanest runs of the window are `PR#1072` (open→merge **25m**, 4 commits) and `PR#1071` (**17m**, 2 commits) — both zero blocking verdicts, both approved twice on the first read. Both PR bodies open by naming what the *old* code did and what the *new* code does, case by case (PR#1072: *"a pod whose `.status.phase` is entirely absent … falls through `select(false)` and is silently uncounted, whereas the old field-selector would have counted it"*). Both approvals cite the same reason: *"the pin fails against the pre-fix source (non-vacuous by construction)"* and *"a pin that fails against the pre-fix source — the vacuous-pin rule satisfied by construction."* This is F2's process change already working when an author happens to do it, and it is the reusable move worth writing into `.agents/fix.yaml` beside the sibling-site line.
2. **A heterogeneous model pool makes the strike protocol nearly free.** Nine homelab rows (`#913`, `#625`, `#866`, `#617`, `#648`, `#622`, `#629`, `#779`, `#892`) take exactly **one** strike, swap to a different model, and go clean — median cost one pod spin-up. The same protocol on oracle-fleet, where every attempt is the same model, produces 5-deep identical failures (F3). The codifiable rule is not "retry less", it is "a strike must swap to a *different* model or it is not a strike".

## Platform KPIs (ADR-103)

**(1) Bucket-A — 38 events (strict), window 2026-08-25 → 2026-08-31, from 89 platform-repo issues filed.** Same rule as r1/r4 (coordinator/launcher, scan, prompt-transport, review reflex/reviewer, loop-state misclassification; excluding pure infra 🚨 alerts, garage/S5 doc waves, product lanes, feature build-out, and stint/goal/post-launch containers), counted as **distinct fault events** so an explicit sprout chain counts once.
- *scan* (14): `#933` (goal-checkpoint trigger (b) counts the post-launch bucket), `#937`(+`#940`) (pre-flight counts wedged Pending as live work), `#944` (block: fixture source-side sentinels compelled but not exempt), `#975` (changes-requested clause has no reviewable_again hold), `#993` (no GOVERNANCE-set footprint check), `#994` (~92% of coordinate runs dispatch nothing), `#998` (phase-absent silently uncounted — the #995 regression), `#1011` (arbitrate state-fp re-armed by per-check conclusions), `#1028` (ratchet blind spot: suite-entrypoint fixtures outside `agents/replay/`), `#1029` (GOAL-CHILD probe can never be green), `#1031` (`ISSUE_LIST_LIMIT` unbound → clause-replay red on every PR), `#1036` (governance-lint has no assembly-lane arm), `#1053` (goal-decompose `Base:` fail-closed), `#1060` (issue-keyed ceiling counts mentioning PRs), `#1070` (`governance_paths()` unescape drops metacharacters)
- *coordinator / launcher* (11): `#916` (strike classifier reads exit_status only — the budget-403 key/account split lands unread), `#917` (goal-budget descendant walk single-repo), `#919` (non-docker rides lack the ephemeral-tier toleration → Pending), `#938` (iac-sentinel edge submissions don't collapse — 14 duplicate scans), `#974` (coordinate WorkflowTemplate OOMKilled — 74 of 76 runs dead in 7h), `#986`(+`#1006`) (updater can clobber a concurrent push; third call site still unguarded), `#990` (opencode wedges at SDK init under enforce egress), `#1004`(+`#1093`) (recurring 401 auth-storm on oracle-fleet dispatches), `#1023` (env-card registry-mirror vars are pod-only), `#1042`(+`#1057`) (probe-class strike/cooldown isolation; probe identity on the write path), `#1069` (fix rounds silently no-op when the App GraphQL quota is exhausted)
- *reviewer / reflex* (4): `#945` (shadow idempotency tag not keyed on `$MODEL`), `#972` (an approved armed PR still merges on a burnt budget), `#1038` (reviewer App token missing `Issues:read` → systematic false "unauthorized scope" blocks), `#1055` (reviewer must never fail into a verdict on an unreadable input)
- *ratchet / pin vacuity* (4): `#914` (tests assert only exit code), `#1007` (race-422 fixture byte-identical to update-fail), `#961` (retro push-belt marker has no reader), `#953` (a direct master push reds every open PR)
- *ledger / loop-state* (5): `#932` (retro success-metric push fails silently → false `RetroReportOverdue`), `#987` (`_budget_from_cr` attributes an arbitrary round), `#988` (float parse outside the best-effort try/except), `#989`(+`#1075`) (retro-session CR parser re-breaks on every emit shape), `#1059` (fix.yaml tier table mis-claims `/docs/` gating)

A **wide** reading that also counts the openrouter-proxy/egress plumbing defects (`#1018`, `#1020`, `#1056`, `#1085`) gives **42**.

**(2) Trend — it did NOT fall, for the second consecutive week.** r4 strict: **15** of 106 filed (14.2%). r1: **28** of 188 (14.9%). r2: **38** of 89 (**42.7%**). Absolute +36%; share ×2.9. Two honest caveats: r1's denominator was inflated by a garage-recovery and an S5 corpus wave that produced almost no loop-logic issues, so the *share* jump overstates the change while the *absolute* rise does not; and the clustering is a judgment call (a stricter one-per-cluster reading gives 33). Either way this is the **second consecutive non-fall**, which is the ADR-103 named trigger to revisit label-carried loop state — and F1, F4 and F5 are all label-or-ledger-carried-state defects, i.e. the trigger and the evidence for it are the same three rows.

**(3) Proposed next gate — `agents/replay/fixtures/pin-vacuity-<clause>/`: a recorded world whose `expected/actions.txt` is identical against pre-fix and post-fix source; expected outcome = `clause-replay` FAILS the PR.** This is r1's mandatory next gate; it has **not** landed (no such fixture exists) and its class is again the highest-recurrence unguarded one: 4 blocking verdicts (PR#997, PR#1014 r2, PR#1066 — *"the ADR-103 ratchet cannot tell the difference"* — and PR#1074, whose body **claimed** the vacuous-pin bar and shipped a pin that no longer reproduces the bug it exists to pin) plus 3 filed issues (`#914`, `#1007`, `#1028`). The `.agents/review.md` bullet that landed 2026-08-30T20:23Z is the human-side half and it is working — PR#1074's block came 2h21m later and cites the bar by name — but a rule the reviewer must re-derive per PR is not a gate. Runner-up, already covered by F1's change rather than a gate: bare-`agent-fix` invisibility (16 live instances).

**(4) Jail $/day-equivalent — not a retro input** (homelab#587), and not computed here.

## Predecessor score

**All six r1 process changes merged; none has had enough runway to move rounds/issue, and one is already measurably working.**

- **r1-F1 (fleet ruling files one queued issue) — MERGED 2026-08-26T08:27Z (PR#947, issue #927) and EXERCISED.** `homelab#1004` is the filing: *"recurring 401 auth-storm circuit-trips on oracle-fleet dispatches (3x in ~3h)"*, closed `agent/done` 08-26, with `#1093` extending it 08-31. The clause did what it was written to do. My F1 is the gap immediately downstream of it, not a failure of it.
- **r1-F5 (IL-T16 phantom predicate → `agent/review`) — MERGED 2026-08-26T13:40Z (PR#957, issue #928).** It shipped with its own blocking round (the reviewer caught the `review_only` selector omitting `agent/error`). I found **no in-window firing** to score: the one row that motivated it (`#778`) has since moved to `agent/blocked`, a human gate the belt correctly will not touch. Live but unexercised.
- **r1-F6 (emit `pick_tier` into the ledger row) — MERGED 2026-08-26T18:17Z (PR#964, issue #929) and WORKING.** Code is at `agents/ledger.py:139-160`/`:354-360`. r1 measured 0 of 25 homelab and 0 of 5 oracle-fleet rows carrying a tier; **4 new tiered rows now exist** (`homelab#1041` sm, `oracle-fleet#279` sm, `#283` xs, `#284` xs), and `homelab#1041` carries **no `agent-budget/*` label**, proving the tier came from the estimator's own CR rather than a human override. This is the single most useful merged change of the set — F6 in this report is only possible because of it.
- **r1-F2 (`DELIM-FIELD` signature) — MERGED 2026-08-30T20:23Z** (`scripts/prompt-transport-lint.py:44`, `:404-440`). ~30h of runway. Zero delimiter-field blocking verdicts in the window after it landed, but n is far too small to claim credit.
- **r1-F3 (vacuous-pin BLOCKING bullet) and r1-F4 (sibling-site sweep line) — MERGED 2026-08-30T20:23Z** in one operator-direct commit (`77222257`): `.agents/review.md:46-48` and `.agents/fix.yaml:112`. Also ~30h. F3's first observable use is PR#1074's block at 22:44Z the same night — the reviewer applying the new bar against a PR that claimed it. Too new to score on rounds; see KPI (3) for why the mechanical half is still needed.

**Did rounds/issue drop?** Not yet, and I will not claim it did. Blocking verdicts per merged agent PR in `homelab`: **0.17** (08-11→08-18, n=90) → **0.57** (r1 window 08-18→08-26, n=120) → **0.53** (08-26→08-31, n=58), with the fully-post slice 08-27→08-31 at **0.44** (n=36) and zero-block PRs 62% → 67%. The direction is right but the three changes aimed at review rework only landed on 08-30T20:23Z, so almost the entire post window predates them; the honest reading is **no measurable movement yet**, re-scoreable in r3 with a full week of runway. The ledger cannot help here either: only one platform row (`homelab#1041`) post-dates 08-26, and F4 shows it should not have been ledgered as terminal at all.

## Evidence confidence

**Ledger blind spots** are taken as briefed and not re-derived: I counted review rounds from PR verdicts throughout (`reviewer_rounds` disagreed with the trail on every deep-dive row I could reach — `#913` says 2 against 14 reviews / 7 blocking verdicts; `#1041` says 0 against 3 blocking verdicts), treated `$0.00` as untracked, and cross-checked wall-time before calling anything slow.

**Wall-time cross-check (done, mixed result).** `circles#77`: `wall_time_s` 116,909s matches PR#79's open→merge of **32h36m** exactly, and its first verdict *was* the approval — pure review-queue latency, 609s active, zero rework. So the fleet's long walls are review idle, as briefed. But `homelab#913`'s `wall_time_s` is 13,089s (3.6h) while PR#915's open→merge is **84,444s (23.5h)** — the field is not PR lifetime on that row, so wall-time is not comparable across rows and I based no finding on it.

**Could not verify:**
- **Deep-dive ranks 2, 4, 6 and 7** (`sleep-tracking#123`, `oracle-fleet#304`, `oracle-fleet#1`, `sleep-tracking#71`) — **50% of the deep-dive set**. `teststuffstash/oracle-fleet` and `teststuffstash/sleep-tracking` return HTTP 404 under **both** the pod's default token and `RETRO_GH_TOKEN`; `installation/repositories` for the fleet token lists only `teststuffstash/openrouter-operator`, while `homelab` and `circles` resolve as public. Those four are scored from ledger fields alone and marked unverifiable above. F3's oracle half therefore rests on ledger `(model, error_class)` sequences plus the platform-repo sibling `#1004`/`#1093`, not on oracle trails.
- **The responder-ledger half of the bucket-A count.** Counted from platform-repo issues only: `kubectl` authenticates as `system:serviceaccount:openrouter-operator:agentstack-worker` and is Forbidden on `homelab` pods, the pushgateway address does not resolve from this pod, and no `aws` CLI is present for `s3://agent-transcripts/`. r1 and r4 had the same limitation, so the 15 → 28 → 38 series is at least like-for-like.
- **Whether the 08-30 auth-storm cluster produced strike comments.** `retry_storms` (harness-level only) shows 3/2/2/3 on the oracle rows, but the `AGENT_STRIKE:` comments that the fleet trigger reads live in the unreachable repo, so I cannot say whether the ≥2-distinct-issues trigger fired on 08-30 and was ignored, or never fired. F3's process change is written to be correct either way.
- **Blocking-verdict counts for 08-18→08-26** hit the 120-item search page limit, so that window's mean (0.57) may be computed on a truncated set; the post-window figures (n=58, n=36) are complete.

TOOL_GAP: gh api repos/teststuffstash/{oracle-fleet,sleep-tracking} — needed for deep-dive ranks 2, 4, 6, 7 and for the oracle strike trails behind F3; 404 under both the default token and RETRO_GH_TOKEN.
TOOL_GAP: responder ledger (kubectl pods / pushgateway / s3 read) — needed for the responder-lane half of the ADR-103 bucket-A count; RBAC-Forbidden, DNS unresolvable, no aws CLI.
