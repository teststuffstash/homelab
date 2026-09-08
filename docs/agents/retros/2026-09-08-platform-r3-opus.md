# platform loop retro r3 — Claude Opus 5 (1M context)

## Summary (≤5 lines)
The loop's most expensive repeat cost this window is **who executes the fix after arbitration**: on 6 of 22 reachable agent PRs the operator hand-pushed an edit or reversed a park, and in 4 of those the arbitration ruling had *already written out the exact edit* — the carrier that would have delivered it to a worker is a known open defect (`homelab#1467`).
The same play has the opposite failure on the other side: the "max 3 logic rounds" invariant is waived one round at a time with no counter — `homelab#1268` was extended to rounds 4, 5, 6 and 7 by four consecutive rulings, while `homelab#1041` was parked at verdict 3 by the same clause.
Branch-currency churn is the loop's largest volume cost: **228 of 339 commits (67%) on agent PRs are `Merge branch 'master'`** — PR#915 drew 164 workflow runs (81 CI, 31 cancelled mid-flight) for 22 content commits, and 11 reviewer rides across the set closed with an explicit "no verdict". The four fixes that landed 2026-09-05 did **not** stop it: PR#1462 accumulated 13 more content-free merges over the 15.9h *after* its last code commit.
On budget, both `xs`-tier dispatches in the ledger (`homelab#1151`, `oracle-fleet#284`) exhausted their $0.25 key on attempt 1 and produced nothing, while `md`/`lg` dispatches used 4–22% of cap — a band problem the r3-F5 flat buffer bump (#258) structurally cannot fix.
Ledger blind spots (`reviewer_rounds`, undecomposed `wall_time_s`, harness-only `retry_storms`, `$0.00` = untracked) are taken as briefed and stated once here: review rounds are counted from PR verdicts throughout, and I confirmed `wall_time_s` is not even open→merge (`homelab#913` reads 13,089s against a 84,444s PR span).

## Findings (ranked, ≤6)

### F1 — Arbitration writes the edit; a human applies it. The directive has no carrier to a worker.

**Evidence.** Across the 22 reachable agent PRs (17 homelab + 5 circles), 19 human touches by `RasmusSoot` on 14 PRs. Ten are routine ADR-110 codeowner gate reads (in-sitting, "corpus session"). The other **six are the operator hand-executing loop work**:

| PR | what the operator did | latency |
|---|---|---|
| #1058 (`homelab#1041`) | "arbitration option 1 applied by hand — commit `f776ebc3` … the two-line edit the 22:07Z ruling wrote out" | ruling 08-30T22:07Z → fix 08-31T05:33Z = **7.4h** |
| #631 (`homelab#625`) | two seat commits: "arbitrate seat fix (PR#631 r1)", "arbitrate seat fix r2 (PR#631)" | in-session |
| #1208 (`homelab#1151`) | "Remedy (b) executed — operator-ordered, seat push `4ecff105`" per the arbitration ruling | in-session |
| #473 (`homelab#379`) | "Round 6 — operator seat, unparking. The park's full remaining edit landed in `42ce182`" + a second comment clearing the error latch | out-of-sitting |
| #915 (`homelab#913`) | operator `CHANGES_REQUESTED` 08-25T20:37Z → coordinator parked `agent/blocked` at 21:13Z → operator un-parked by hand 08-26T06:33Z | park→un-park = **9.3h** |
| #790 (`homelab#778`) | closed the PR unmerged by operator ruling | terminal |

Four of the six (#1058, #631, #1208, #473) are the operator applying an edit a ruling or review had already specified in full.

**Mechanism (falsifiable).** `homelab#1467` — open, `agent/review`, filed 2026-09-05 — states it directly: *"an arbitrate directive posted on the PR (or lacking the ARBITRATE token) never reaches the worker — the fix round silently no-ops."* So when arbitration rules "apply this edit", the only executor with a working path to the branch is the seat. The `agent/arbitrate` row's own doctrine ("automation continues, judgment decides") is half-true: judgment decides and then judgment also types. Falsify by finding a ruling whose named edit was applied by a dispatched worker round rather than by a human push.

**Process change.** One clause on the `agent/arbitrate` row of `agents/coordinator/README.md`, beside the existing "automation continues, judgment decides": *a ruling that names a concrete edit sets `agent/queued` with the ruling as the round directive — never `agent/blocked`; `agent/blocked` is reserved for rulings that need a decision, not rulings that need typing.* (Blocked on `homelab#1467` shipping the carrier; the clause is what makes the carrier load-bearing.)

**Expected saving — rail 1, the only finding here that reaches it.** 4 out-of-sitting operator summons removed from the 22-PR set. At E ≈ €20–30 per summons that is **€80–120**, plus ~17h of measured park/ruling latency (7.4h + 9.3h on the two timestamped cases). Parent binding: standalone-honest (aggregates five origin issues).

---

### F2 — The round cap is waived one round at a time, and nothing counts the waivers

**Evidence.** `homelab#1268` / PR#1273, ledger 7 rounds, all `clean`, all CI-green, $0.0428, 30.7h open→merge. The trail shows the bound firing and then being overridden four times:
- `2026-09-02T06:07:23Z` — "ARBITRATE (ci-red, FU-115): 3 fix rounds counted on PR #1273 and CI still red at `c9231cb4` (**cap 3**)"
- `06:38:00Z` — "**Arbitration ruling — re-dispatch with clarified instructions** … I rule bullet 1 of the escalation table"
- `07:03:17Z` — "**round 5 dispatched**"
- `07:56:00Z` — "**round 6 dispatched**"
- `08:35:03Z` — "**round 7 dispatched**"

The same clause on similar input does the opposite: PR#1058 (`homelab#1041`), `2026-08-30T22:07:35Z` — "reviewer verdict 3: **`agent/blocked`, not a round 6** (the pre-committed bound fires)". Fleet-wide, **10 of 33 structured rows carry 5+ counted rounds — 17 rounds past the round-4 ceiling** (`#913` 7, `#1268` 7, `#1205` 6, `#1151` 6, `circles#32` 6, `#1041`/`circles#19`/`oracle#337`/`#892`/`#379` 5).

**Mechanism.** The invariants line in `agents/coordinator/README.md` bounds *logic rounds*, and the escalation table's bullet 1 ("re-dispatch with a named clarification") is exempt from that bound by construction — a clarified re-dispatch is not counted as a logic round, so bullet 1 can be selected an unbounded number of times on the same PR. Falsify by finding a ruling that refused bullet 1 *because* bullet 1 had already been used on that issue.

**Process change.** One clause on the same invariants line in `agents/coordinator/README.md` that already carries the strike rule: *bullet-1 re-dispatch is available once per issue; a second clarified re-dispatch on the same issue is the bound firing — park it.*

**Expected saving — rails 2–3 only, stated honestly.** 17 worker rounds + their paired reviewer and coordinator rides. Paid-API share is small (`#1268` billed $0.0428 across 7 rounds ≈ $0.006/round; `oracle-fleet#355` $0.7092 across 4 ≈ $0.18/round) → order **$0.10–$1.50 per window**; the subscription share is cents at the amortized price. The real recovery is wall-time: the four `#1268` waivers span 06:07Z→08:35Z inside a 30.7h PR. Parent binding: `homelab#1268` (singular origin).

---

### F3 — Two thirds of every agent PR's commits carry no content, and the 2026-09-05 fixes did not stop it

**Evidence.** Across the 22 reachable PRs, **228 of 339 commits (67%) are `Merge branch 'master' into fix/…`** — homelab 225/321 (70%), circles 3/18 (17%). The extreme case, PR#915 (`homelab#913`): 81 commits, 59 of them merges, **22 content commits**, against **164 workflow runs on that branch** — 81 `CI`, 81 `renovate-approve`, **31 `cancelled`** (each killed mid-flight by the next merge). The reviewer was dispatched into that churn and returned no verdict five times: `STANDING ASIDE: checks-pending` at heads `01d7a196`, `33cf32f5`, `8d0e01e6`, `caa6b100`, plus one `own-verdict-at-head` — **11 such no-verdict rides across the 22 PRs**.

The class is already diagnosed four ways (`#1441` governance-lint reds any PR merely behind master → the updater merges constantly; `#1452` updater should update only when merge-ready; `#1403` and `#1438` reviewer STEP-0 arms tripping on the churned tip), **all closed 2026-09-05**. It survived them: PR#1462 (`homelab#1439`) took its last content commit at `2026-09-05T23:20:26Z` and merged at `2026-09-06T15:13:05Z` — **15.9h later, having accumulated 13 further content-free merges** and 42 workflow runs (5 cancelled).

**Mechanism.** The reviewer is level-triggered on HEAD; the updater moves HEAD on a cadence unrelated to content. Every merge invalidates the in-flight CI run, so checks are pending more often than settled, so the reflex's dispatch lands on `checks-pending` and burns a ride for a "no verdict". Falsify by finding a churned PR whose reviewer dispatches all landed on settled checks.

**Process change.** One clause on the `agent/review` row of `agents/coordinator/README.md`: *the reflex does not dispatch a review while the branch has an update-in-flight — an update-branch push within the last CI settle window defers the ride rather than spending it on a standing-aside.* (`#1452` fixes the updater's cadence; this stops the reflex paying for the cadence that remains.)

**Expected saving — rail 3 + wall-time.** 11 no-verdict reviewer rides per 22 PRs (~cents at the amortized subscription price), ~59 content-free CI runs on a single PR, and the measurable prize: **15.9h of post-content idle on PR#1462**, consistent with the fleet ratio that **active run is 8% of wall time** (161,068s of 2,038,410s across 33 rows). Parent binding: standalone-honest.

---

### F4 — The `xs` band is below the floor cost of a first round: 2 of 2 `xs` dispatches 403'd on attempt 1

**Evidence.** Every `agent-budget/xs` row in the ledger died the same way:
- `homelab#1151` — cap $0.25, round 1 `deepseek/deepseek-v4-flash` → `budget-403` / `budget-exhausted-key`, then 6 rounds on haiku/opencode-go. Issue total $0.2415, i.e. essentially the dead round.
- `oracle-fleet#284` — cap $0.25, round 1 `deepseek/deepseek-v4-flash` → `budget-403` / `budget-exhausted-key`, then 3 rounds on sonnet. Issue total $0.2614.

The other direction is just as wrong: `homelab#1268` used **4%** of its `md` $1.00 cap, `sleep-tracking#43` 5%, `circles#19` 17%, `circles#32` 22%, `oracle-fleet#279` 20%. So the ladder over-sizes `md`/`lg` by ~5–20× while `xs` cannot fund one round.

**Mechanism.** `estimate_budget.py` documents `DEFAULT_CACHE_HIT = 0.0` and a headroom multiplier applied to the *point estimate* before `pick_tier`. r3-F5 (#258, merged 2026-08-11) raised that multiplier 1.5 → 2.0 — which scales the estimate uniformly and therefore cannot change where the *band edges* sit. A task whose true first-round cost exceeds $0.25 lands in `xs` whenever the estimate is small, and the cap then 403s before any artifact exists. Falsify by finding an `xs` dispatch that completed a round on a paid model.

**Process change.** One band edit in `estimate_budget.py`'s tier ladder: **raise the `xs` floor to $0.35, or drop `xs` from `pick_tier` entirely** — the module's own docstring says "over-sizing slightly beats throttling a legit fix, and an unspent cap costs $0", and the two observed `xs` rides are exactly the throttled-legit-fix case it warns about.

**Expected saving — rail 2, exact.** ≈**$0.50 of billed OpenRouter** ( $0.2415 + $0.2614 ) burned for zero artifact in this window, plus 2 wasted worker pods and 2 forced mid-round model swaps. n = 2, stated as small. Parent binding: standalone-honest (spans two repos).

---

### F5 — Harness death is a property of one model family, and the swap protocol is allowed to swap inside it

**Evidence.** 148 worker attempts across 33 structured rows. **All 12 `harness-death` exits are on the deepseek/xiaomi family** — `deepseek-v4-flash` 9, `deepseek-v4-flash-0731` 2, `xiaomi/mimo-v2.5` 1 — and **zero on `haiku` (69 attempts) or `sonnet` (3)**. Error classes: `goose-32602-truncation` 7, `repetition-loop` 5. Non-clean rate: deepseek-v4-flash 37% (25/67) vs haiku 13% (9/69), and haiku's 9 are all `ci-failed`/`failed`, never a harness death. **20 of 33 rows (61%) lost their first attempt.**

The swap protocol does not know about the family. `sleep-tracking#123` struck `xiaomi/mimo-v2.5` (`goose-32602-truncation`) and swapped to **`deepseek/deepseek-v4-flash-0731`, which died the same way**, before a third swap landed clean. `oracle-fleet#272` swapped `-0731` → `-flash` and drew an `auth-storm`. `homelab#1439` "swapped" `haiku` → `haiku`.

**Mechanism.** r2-F3's merged clause (`#1104`) bans a second strike with the *identical* `(model, error_class)` pair; a sibling model with the same harness failure mode is still a legal swap target, and the swap target is otherwise unconstrained. Falsify by finding a post-strike swap that was rejected for family reasons.

**Process change.** Extend the same invariants clause in `agents/coordinator/README.md` that `#1104` added, by one predicate: *a swap after `goose-32602-truncation` or `repetition-loop` must leave the model family — a sibling of the striking model is not a swap.*

**Expected saving — rail 2 + pods.** 1–2 guaranteed-dead rides per window at the observed rate (2 within-family swaps in 21 strikes), each a full pod spin-up; on `sleep-tracking#123` the wasted sibling ride sat inside a 302h wall. Parent binding: standalone-honest.

## Proposed process changes

| change | artifact | expected saving | confidence |
|---|---|---|---|
| A ruling that names a concrete edit sets `agent/queued` + the directive, never `agent/blocked` | `agents/coordinator/README.md` — `agent/arbitrate` state-machine row | **rail 1:** 4 out-of-sitting summons ≈ **€80–120**/window + ~17h park latency | High — 4 hand-pushes quoted verbatim; carrier defect independently filed as `homelab#1467` (open) |
| Bullet-1 re-dispatch is available once per issue; a second use is the bound firing | `agents/coordinator/README.md` — invariants line ("bounded rounds") | rails 2–3: 17 rounds + paired rides ≈ **$0.10–$1.50** + the 2.5h waiver span inside `#1268`'s 30.7h | High — the four waivers are quoted rulings; the opposite ruling on `#1041` is the control |
| The reflex defers, not spends, a ride while an update-branch push is in flight | `agents/coordinator/README.md` — `agent/review` state-machine row | rail 3 (cents) + **15.9h** post-content idle on PR#1462; 11 no-verdict rides / 22 PRs | Medium-high — churn measured; the deferral's effect on settle time is projected |
| Raise the `xs` floor to $0.35 or drop `xs` from the ladder | `estimate_budget.py` — the `pick_tier` tier ladder | **rail 2, exact: ≈$0.50**/window billed for zero artifact + 2 pods + 2 forced swaps | Medium — mechanism is clean, n = 2 |
| A post-`goose-32602-truncation`/`repetition-loop` swap must leave the model family | `agents/coordinator/README.md` — invariants line, extending `#1104`'s clause | rail 2: 1–2 dead pod rides/window | Medium — 12/12 harness deaths in one family is decisive; 2/21 within-family swaps is thin |

Following the `#1101`/`#949` precedent, this cell proposes and does not file; the batch container is the next corpus session's to author. Bindings are named per finding above.

## Task granularity (per deep-dive task)

| # | task | verdict | evidence |
|---|---|---|---|
| 1 | `homelab#913` | **should-have-been-one** | The split is the defect. `#894` shipped `item_class_push` + `board --machine` + the belt with **zero call sites** wired; `#913` then had to wire ~14 sites *and* fix two emitter-semantics defects (pushgateway group-replace clobbering, push-time vs first-transition stamps) that only became visible at wiring. That is textbook cross-chunk rework: 7 rounds, 14 review submissions, 6 `CHANGES_REQUESTED`, and a codeowner gate that itself flagged a half-landed fix. Emitter + call sites belonged in one PR. |
| 2 | `sleep-tracking#123` | **cannot judge** | Trail unreachable (see Evidence confidence). Ledger shape — 4 logic rounds, 2 strikes, 4 distinct models, two terminal `ci-red` rounds — is consistent with either reading. |
| 3 | `homelab#1041` | **chunked-right; in-chunk rework** | Scoped to "acceptance item 2 only" of Goal #1039, native `blockedBy` on #1040. The rounds burned on one shape repeated three times: an MCP-config guard applied to one arm and not its sibling (reviewer arm vs worker arm), closed by a **two-line** guard. Not cross-chunk friction — a sibling-site miss *inside* the chunk. |
| 4 | `oracle-fleet#304` | **not a granularity problem** | 5 identical `(deepseek-v4-flash, repetition-loop)` strikes, 1 logic round, 13,165s active, no PR. A routing fault (r2-F3, now `#1104`), not a chunk size. Trail unreachable; ledger-only. |
| 5 | `homelab#625` | **chunked-right** | One deliverable (absorb `coordinator-session.sh` exit 3 in the dispatch leg), 4 rounds, merged 1h56m after PR open. Both blocking findings were in-chunk defects of this PR's own fix (`grep -m1` not draining past its first match; the FU-121 raced-close skip) — caught at r1 and r2 and fixed. This is the shape the loop should aim for. |
| 6 | `oracle-fleet#1` | **cannot judge** | Trail unreachable; legacy scalar-`rounds` ledger form carries no per-round detail. |
| 7 | `sleep-tracking#71` | **cannot judge** | Trail unreachable; scalar-`rounds` form. Ledger shows 3 attempts on 3 different free/cheap models ending `blocked-deliberate` — consistent with the `AGENT_INFEASIBLE` terminal (#257) working. |
| 8 | `homelab#778` | **mis-chunked at authoring; fan-out attempted and abandoned** | The body records the chunk was authored off a stale FU-161 tracker line — "the original scope already shipped" (#469 → PR#499, merged 08-18) — then re-scoped the same day into **five unrelated deliverables** (prove a canary organically / Go-rail cells / rung-2 / pool depth / void tainted verdicts), one of which was immediately moved out to FU-181. 3 rounds on 3 models ending `budget-403`; PR#790 closed unmerged: *"Closed per operator ruling (fan-out pilot close) — the experiment stops here."* The failure is upstream of model size: a chunk whose premise was stale. |

## Wins to codify

**`homelab#148` / PR#150 — one home, first round, 778s open→merge.** Single round, single review, zero `CHANGES_REQUESTED`, 535s active run. The approval states the reusable move: *"The fix is better than the issue asked for: instead of duplicating the single-line treatment onto the second path, it extracts `_record_clear()` so 'N clears stay 1 line' is implemented once."*

This is the exact inverse of the shape that cost `homelab#1041` its final round (a guard on the reviewer arm and not the worker arm) and of the class `homelab#1151` had to be filed to lint (`classify_touches()` **one-home** + collapsing the fix-debounce inline copy). It is worth codifying because the loop keeps paying for its absence and keeps naming it after the fact.

**Codify into `.agents/fix.yaml`'s PR-body requirements block**, beside r1-F4's sibling-site line at `:112`: *"If the fix would apply the same treatment at a second call site, extract the treatment to one home and call it from both; name the home in the PR body."* r1-F4's line asks the author to *enumerate* sibling sites; this asks them to *collapse* them, which is what the two cheapest merges in the set actually did.

Second, smaller win: **`circles` PRs merge with 17% merge-from-master commits against homelab's 70%** (3/18 vs 225/321) and no standing-aside storms. Whatever circles' updater cadence is, it is the control group for F3 and worth reading before writing the deferral clause.

## Platform KPIs (ADR-103)

**Bucket-A — 31 events, window 2026-09-01 → 2026-09-07, from 136 platform-repo issues filed (23%).** Counted from `teststuffstash/homelab` issues under r2's rule (coordinator/launcher, scan, prompt-transport, review reflex/reviewer, replay gate, loop-state misclassification; excluding pure infra 🚨 alerts, garage, S5 doc waves, product/edge lanes, feature build-out, and stint/goal/post-launch/retro-batch containers), as distinct fault events so a sprout chain counts once: `#1249 #1255 #1261 #1267 #1268 #1280 #1291 #1294 #1314 #1342 #1345 #1349 #1350 #1369 #1374 #1381 #1390 #1392 #1403 #1427 #1438 #1439 #1440 #1441 #1442 #1444 #1450 #1451 #1456 #1467 #1472`. A conservative core dropping the four judgment calls (`#1268 #1291 #1374 #1390`) gives **27**.

**Trend — first fall in the series, but the published series is not like-for-like.** r2 published 15 → 28 → 38 from a stated 89-issue window; my `is:issue` query returns **120** issues for that same 2026-08-25 → 08-31 window, so I cannot reproduce their denominator. Applying **my own rule to both windows** as a control: **49 events / 120 issues (41%) last week → 31 / 136 (23%) this week** — a fall in both absolute count and share. Read against the published series the direction is a fall; read strictly, ADR-103's "sustained non-fall" trigger for revisiting label-carried loop state is **not** met this week, but one window is not a trend and the r2 → r3 comparison rests on my re-count, not theirs.

**Proposed next gate (highest-recurrence unguarded class this week): a scan clause that re-emits on unchanged state or has no retiring edge — 5 events.** `#1345` (state-fp debounce swallows a no-op round after an arbitrate re-dispatch), `#1444` (merge-conflict clause re-dispatches on unchanged state — no hold, no reader, no debounce), `#1450` (goal-checkpoint trigger (b) has no retiring edge, re-fires from tree-empty until a human), `#1472` (merged-closeout C6 has no state-fp debounce — `oracle-fleet#397` drew **9 redundant dispatches**), `#1314` (footprint hold releases at PR-open instead of merge). The class also recurred last window (`#1011`, `#1108`), so it is not new noise.

**The gate:** extend the ADR-103 co-change ratchet — which already compels a fixture per scan edit — to compel the *shape*: every clause that emits a dispatch unit must be pinned by a **"second tick, unchanged state ⇒ zero units"** fixture, and every clause with a terminal condition by a **"condition retired ⇒ clause stops emitting"** fixture. This reuses the existing `agents/replay/` machinery and the pin-vacuity precedent (`#1107`); it adds no new gate.

## Predecessor score

**r2 (2026-08-31, children #1102–#1107 — all merged) — mixed, one clean hold and one clean miss.**
- **`#1104` (a second strike with identical `(model, error_class)` routes to `agent/error`) — HOLDS, small n.** The 7 ledger rows after 2026-08-31 (`homelab#1151 #1149 #1268 #1205 #1439`, `oracle-fleet#337 #355`) carry 3 strikes and **zero repeated identical pairs**. Before it: 8 such repeats (`oracle-fleet#304` ×4, `#279` ×2, `#273`, `sleep-tracking#123`). `oracle-fleet#304` — the worst row on the board, 5 identical strikes for zero artifact — occurred at 2026-08-31T03:00Z, hours before the clause closed.
- **`#1106` (closed issue + merged PR + stale label → `agent/done`) — MERGED BUT NOT OBSERVABLY FIRING.** On 2026-09-08, `homelab#913` (closed 08-26, PR#915 **merged**) and `homelab#625` (closed 08-19, PR#631 **merged**) still carry `agent/blocked`. Both are ledger rows in this retro's deep-dive set, both ranked as blocked failures on a label that is 8–20 days stale. The reconciler's predicate matches them exactly; it has not reconciled them.
- **`#1103` (predicate-REPLACE diffs enumerate the old accepted-input set) — too new to score;** no PR in this window's reachable set carries such a body block.

**r1 (2026-08-25) — `#931` (r1-F3+F4, sibling-site sweep line at `.agents/fix.yaml:112`) merged 2026-08-30T20:23Z and did not prevent its own class the same night.** PR#1058's blocking finding at **2026-08-30T22:02Z** — 1h39m later — is precisely a sibling-site miss (guard on the reviewer arm, absent on the worker arm), and it went on to cost the park and the operator hand-push in F1. This is the evidence behind the Wins section's proposal to change the line from *enumerate* to *collapse*.

**r3 (2026-08-11) — both scoreable children missed.**
- **`#256` (`GOOSE_MAX_TOKENS=16384`, titled "the solved class still killing rounds") — did NOT close the class.** Five `goose-32602-truncation` harness deaths landed after it merged: `homelab#791` (08-23), `oracle-fleet#272` (08-26), `sleep-tracking#123` ×2 (08-30), `homelab#1205` (09-05). This is the direct evidence for F5: the class is a model-family property, not a token-limit setting.
- **`#258` (estimator buffer 1.5 → 2.0) — did NOT stop cap saturation.** Post-merge `xs`/`sm` rows still land at 97–142% of cap (`homelab#1041` 105%, `#1205` 100%, `#1151` 97%, `oracle-fleet#284` 105%, `#355` 142%) and both `xs` rows 403'd on attempt 1, while `md`/`lg` sit at 4–22%. Scaling the estimate cannot fix a band edge — F4.
- `#257` (`AGENT_INFEASIBLE` terminal) is in use (`blocked-deliberate` / `worker-stop-report` on `homelab#876`, `sleep-tracking#71`); no failure observed.

**Did rounds/issue drop?** Not measurably. Mean counted rounds per structured row is 3.8 (127 logic rounds / 33 rows), with 10 rows past the round-4 ceiling — the r2/r3 changes targeted strike routing, ledger fidelity and label reconciliation, none of which touch the round loop. F1 and F2 are the first proposals in this series aimed at it.

## Evidence confidence

**Unreachable trails — half the deep-dive set.** Ranks 2, 4, 6 and 7 (`sleep-tracking#123`, `oracle-fleet#304`, `oracle-fleet#1`, `sleep-tracking#71`) are judged from ledger fields only. `RETRO_GH_TOKEN` was present and works — it reads `teststuffstash/homelab` and `teststuffstash/circles` — but `teststuffstash/sleep-tracking` and `teststuffstash/oracle-fleet` return **404 under both the fleet token and the session token, and are absent from `orgs/teststuffstash/repos`** (which lists `sleep-iac` and `circles-iac`, no `oracle-fleet`, no `sleep-tracking`). Per homelab#587 I have not guessed at those trails: F5's within-family swap evidence for `sleep-tracking#123` and all of `oracle-fleet#304`'s treatment rest on ledger rows alone, and rank 2's 302h wall could not be cross-checked against PR open→merge.

TOOL_GAP: gh (cross-repo read via RETRO_GH_TOKEN) — needed for the `sleep-tracking`/`oracle-fleet` issue+PR trails behind deep-dive ranks 2/4/6/7; both slugs 404 under the fleet token and are absent from the org repo list.

**Other limits.**
- **The responder-ledger half of bucket-A** is again missing: counted from platform-repo issues only, as in r1/r2/r4. I did not attempt `kubectl`/pushgateway/S3 reads, which r2 recorded as RBAC-Forbidden / unresolvable / no `aws` CLI from this pod — so the same TOOL_GAP applies and is not re-emitted.
- **The bucket-A trend is my re-count, not r2's.** My denominator for r2's own window (120 vs their 89) does not reconcile, so the 15 → 28 → 38 → 31 series should be read as 49 → 31 under one consistent rule, and the four judgment-call classifications are named above so the number can be audited.
- **Cost rails 2 and 3 are partly unmeasurable.** 15 of 40 rows report `total_cost_usd` 0.00, and `haiku` — **69 of 148 attempts, 47% of the fleet's worker rides** — is on the untracked subscription rail. The 2026-08-31 operator ruling requires rail-3 savings at both cash-amortized and API-equivalent prices; the ledger emits neither for the rail carrying half the attempts, so every rail-3 figure above is stated as "cents at the amortized price" rather than computed. This is an emitter gap adjacent to the FU-058 brief-v2(b) set, not a finding I have priced.
- **F4 rests on n = 2** (`homelab#1151`, `oracle-fleet#284`) — the only two `xs` rows in the ledger. The mechanism is clean and the direction is unambiguous, but a third counter-example would weaken it.
- **F3's deferral clause is projected, not measured.** The churn (228/339 commits, 164 runs on PR#915, 15.9h idle on PR#1462) and the 11 no-verdict rides are counted; how much settle-time a deferral recovers is not.
- **`renovate-approve` runs** (81 on the PR#915 branch, 21 on PR#1462) are counted in the workflow totals but are `skipped` in the majority of cases; the CI-run figures I cite for F3 are the `CI` workflow alone.
