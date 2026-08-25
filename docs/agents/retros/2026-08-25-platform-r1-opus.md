# platform loop retro r1 — Claude Opus 5 (1M context)

## Summary (≤5 lines)
Rounds are not lost to model capability: 24 `agent/done` rows ran **54 rounds after their PR was already worker-clean and CI-green**, and every one I traced was a real reviewer block — so CI-green is not evidence of correctness here, and the review round-trip *is* the loop's throughput.
Those 25 blocking verdicts concentrate in three author-blind spots that are all mechanically guardable today: shell/jq text handling (9), incomplete sweeps of a pattern (6), and new replay pins that prove nothing (5).
The single largest one-day cost was **not** a loop-logic defect: one held Go-rail quota latch was ridden into 15 times over 7h22m — and the loop *diagnosed it correctly at 15:04Z*, then paid 11 more times because the ruling was a comment, not a queued issue.
Ledger blind spots (`reviewer_rounds`, undecomposed `wall_time_s`, harness-only `retry_storms`, `$0.00` = untracked) are taken as briefed and not re-derived; platform review latency is **healthy** (median 26 min to first blocking verdict), so the 77% unaccounted fleet wall-time is a circles/oracle/sleep tail, not a platform one.
Bucket-A did not fall: 15 → 28 events, flat as a share of a 77%-larger filing week.

## Findings (ranked, ≤6)

### F1 — A correctly-diagnosed fleet fault is a comment, not a work item, so the loop kept paying for it 11 more times

**Evidence.** 2026-08-19, `teststuffstash/homelab`: 15 `AGENT_STRIKE` comments across 15 distinct issues between 11:47:18Z and 19:09:10Z, all carrying the identical log `API Error: Request rejected (429) · Monthly usage limit reached. Resets in 24 days`. Six are ledger rows and each shows a wasted round-1 (`homelab#625` r1, `#617` r1, `#622` r1, `#629` r1, `#630` r1, `#648` r1 — all `failed`/`nonzero-exit-1`).

The r4 F2 fleet rule **worked**: at 15:04:09Z the coordinator emitted one `AGENT_ERROR: infra-class strike on 4 issues`, correctly identified the mechanism (*"Go rail dispatched into a HELD capacity latch"*), probed `/opencode-limit` live (`{"limited": true, "reason": "observed-429", "remaining_s": 2146387}`), named the exact unfired code path (`agent-session.sh` Go arm, `:1503` `*)` capacity case, which should have degraded to `claude/haiku`), priced it (*"a full pod spin-up + devbox install (~2 min) for a guaranteed failure"*), forecast it (*"will repeat on every Go-primary dispatch until the ~2026-09-12 monthly reset"*), and correctly withheld `agent/error` labels because the fallback chain was live. It ended with **"Operator ask, once"**.

Eleven more strikes followed that ruling (15:55, 16:10, 17:07, 17:08, 17:10, 17:15, 17:22, 18:02, 18:13, 18:29, 19:09Z), and at 18:19:17Z a second `AGENT_ERROR` on `#629` repeated the same ask 3h15m later.

The controlled contrast is inside the same window. The ruling had two halves. The **attribution** half was filed as an ordinary issue (`homelab#629`, *"AGENT_STRIKE records the wrong model for a Go-rail ride"*) → PR#643 opened 17:23Z, merged 18:32Z — **1h09m, one round**. The **dispatch-gate** half was only an operator ask in a comment → still unfixed at 19:09Z.

**Mechanism (falsifiable).** `agents/coordinator/README.md`'s `agent/error` row defines the STRIKE-channel sibling as *"emit one `AGENT_ERROR: <what>`"* — a label-and-comment terminal, and the row's own instruction is *"surface it and move on."* Nothing converts a fleet ruling into a dispatchable work item, so a fault the loop can fix in ~1 hour survives as prose. Falsify by finding a fleet `AGENT_ERROR` whose emission alone stopped further same-class strikes.

**Process change.** One clause appended to the STRIKE-channel sibling on the `agent/error` row in `agents/coordinator/README.md`: *the same ruling also opens ONE `agent-fix` + `agent/queued` issue against the platform repo naming the gate that did not fire, and links it in the comment — a fleet ruling is filed, not asked.* This is inside the coordinator's stated write surface (labels, comments, `gh`) and reuses the S6 bind-at-filing rule already in the brief.

**Expected saving.** At `#629`→PR#643's measured 1h09m turnaround, filing at 15:04Z lands the gate ~16:15Z: **9 of the 15 strikes avoided** (17:07Z onward), each ~2 min of pod spin-up + devbox install for a guaranteed failure, plus 9 round-1 restarts. The ruling's own forecast puts the untreated tail at ~24 days.

---

### F2 — Nine of 25 blocking verdicts are shell/jq text handling, and an existing mechanical guard already owns exactly this class

**Evidence.** Across 21 platform PRs, 25 `CHANGES_REQUESTED`. Nine are text-handling defects in `agents/*.sh`, all shipped CI-green:
- PR#631 r1 — `grep -m1 "^${clause}|"` re-evaluated against the unmodified `$units`, never drains past its first same-clause match
- PR#863 r1 — `grep -F -m1 "${qbase}|"`, unanchored substring, `big-master` sorts first and steals `master`'s count
- PR#863 r2 — `[scan(...)] | first` returns an array; `@tsv` rejects it and jq halts the whole queued-issue stream for that tick
- PR#863 r3 — POSIX `read` collapses consecutive tabs; empty `qparent` shifts `qbase` into it
- PR#858 r3 — fixture file with no trailing newline, `while read` silently drops the last row; `PARITY_ISSUES` value with embedded spaces
- PR#626 r1 — `LOOP_FETCH` missing its trailing `; ` → `export GH_TOKENtouch /work/session-start`, breaks *every* coordinator session
- PR#473 r3 — unescaped `$ISSUE`/`$HERE`/`$0` inside an unquoted `<<PREP` heredoc, baked in at construction
- PR#803 r2 — `[ "$MODEL_RAIL" = "go" ]` against the canonical vocabulary `opencode-go`
- PR#631 r2 — a new `while` silently repoints an existing `continue` into an unbounded tight loop

Self-filed sibling this week: `homelab#875` (the tab-IFS comment is stale — *"it is four since"*).

**Mechanism.** `scripts/prompt-transport-lint.py` exists precisely for this class — its docstring says *"the durable warnings for #1 and #3 were written down and did not prevent #2 or #4. Compliance is the gap, so the class needs a GUARD, not another warning"* — and it carries five signatures (`JQ-QUOTING`, `HEREDOC-DOLLAR-DIGIT`, `SQ-PROSE`, `HEREDOC-BACKTICK`, `HEREDOC-FN-DOLLAR`), each added after an incident. All five guard **expansion/quoting across a transport boundary**. None guards the **delimiter-field** family, which is where four of this window's blocking rounds landed.

**Process change.** Add one signature to `scripts/prompt-transport-lint.py`, following its established add-after-incident shape: `DELIM-FIELD` — an unanchored `grep -F`/`grep -m1 "$var<delim>"` lookup against a `|`-delimited table, and a `read`/`while read` over a tab-delimited stream with an optional field that can be empty. Precedent for the exact move: `homelab#734` added `HEREDOC-FN-DOLLAR` after PR#727.

**Expected saving.** 4 of 25 blocking rounds directly (PR#631 r1, PR#863 r1, PR#863 r3, PR#858 r3). On PR#863 that is all three of its blocking rounds — and PR#863's own ledger row (`homelab#849`) shows 4 attempts and 7,246s wall for a one-line predicate fix.

---

### F3 — The ratchet gates assertion *weakening* but not assertion *vacuity*, so "additive" pins ship proving nothing

**Evidence.** Five of 25 blocking verdicts name a new-but-vacuous pin; three of them are the **sole** block:
- PR#631 r1 — *"the replay fixture pins the buggy behavior instead of the fix it's meant to ratchet"*
- PR#626 r2 (sole) — the `>>>REPLAY:loop-fetch-guard>>>` sentinel is never referenced by `fixture.yaml`; `bridge.sh` hand-transcribes the fixed string instead
- PR#863 r1 — *"the new fixture doesn't cover a collision case, and `clause-replay` only replays that fixture's own crafted values, so CI green doesn't rule this out"*
- PR#858 r3 (sole) — *"the fixture this round adds to prove the fix doesn't actually verify anything"*
- PR#786 r3 (sole) — *"the self-test pin added alongside it doesn't actually exercise the bug it claims to catch"*

Self-filed siblings this week, same shape: `#690` (*"fixture asserts a recomputed STRIKE_LINE, not the real one"*), `#851` (*"restates busy_fps instead of executing it"*), `#830` (*"replay pin missing"*), `#914` (*"tests assert only exit code, never that rows are restricted"*).

**Mechanism.** `.agents/review.md` §BLOCKING blocks *"an edit or removal of an EXISTING replay assertion or recorded world"* and explicitly rules the other direction ordinary: *"additive rows are ordinary work."* So a pin that passes both before and after the diff is inside the rubric. `.agents/fix.yaml` carries no counterweight — grep over all 165 lines for `RED` / `red→green` / `executable pin` returns zero hits. Falsify by finding a merged platform PR whose new fixture is shown failing against pre-fix source.

**Process change.** One bullet in `.agents/review.md` §BLOCKING, beside the existing weakened-assertion bullet: *"**A new replay world, `expected/actions.txt` row, or `agents/*-test.sh` pin that does not fail against the pre-fix source.** The PR body shows the red run. An additive pin that passes both before and after the diff is blocking."* `.agents/**` is CODEOWNERS-gated → propose in the PR, flagged.

**Expected saving.** 5 of 25 blocking rounds (20%). On PR#858 and PR#863 the vacuous-pin round is the third of three, i.e. the one that consumes the bounded-rounds ceiling.

---

### F4 — Six of 25 blocks are incomplete sweeps: the reported site is fixed, its siblings in the same diff are not

**Evidence.**
- PR#789 — the lock-then-ring pattern is correct at 2 of the 6 new call sites: *"the other two in this same diff get this right — so this is an inconsistent, incomplete application of the PR's own correct pattern, not a design choice"*
- PR#643 — *"the same `case "$MODEL" in ...` block this PR touches has a direct sibling arm with the identical defect"*
- PR#788 — the dual-rail latch fallback *"is silently dropped for two of the three wired lanes"*
- PR#802 r1 — the `elif or_leg:` branch *"reuses the generic header-forward path instead of the allowlist+credential-swap pattern the sibling `go_leg`/`zen_leg` branches use for the exact same kind of cross-provider egress"*
- PR#858 r2 — *"only partially addresses the CHANGES_REQUESTED finding from the previous round"*
- PR#836 — the exemption is required in both directions; *"that half is missing"*

**Mechanism.** `.agents/review.md` already mandates that in-diff findings block rather than defer (*"codeowner economics, operator 2026-08-12"*), so the reviewer re-reads the whole diff each round — but `.agents/fix.yaml`'s PR-body requirements ask only for the fix and its red→green evidence. Nothing asks the round to enumerate the sibling sites of the predicate it changed, so the sweep is left to the reviewer, one site per round.

**Process change.** One line added to `.agents/fix.yaml`'s PR-body requirements block (alongside the existing `Fixes #{{ issue }}` line at :100): *"If the finding is a pattern — a call site, a `case` arm, a rail lane, a per-repo loop — the PR body lists every sibling site of the changed predicate and states which were fixed and why the rest need no change."*

**Expected saving.** 6 of 25 blocking rounds. Each avoided round on the platform stack is ~1,559s median to the next verdict plus a worker session.

---

### F5 — `agent/review` with no open PR is a terminal sink invisible to every scan class

**Evidence.** `homelab#778` (rank 4). PR#790 was closed at the fan-out pilot's close, 2026-08-23 ~15:32Z. The issue then sat untouched until a goal checkpoint hand-corrected it at 2026-08-24T10:28:42Z — **18h56m** — in the coordinator's own words: *"This issue has sat `agent/review` since 2026-08-23 with **no open PR** — #790 was closed at the fan-out pilot's close and #794 merged. Nothing in the loop picks up an issue in that state, so the goal's last pre-flip criterion has had no motion for a day."* The stall held goal #775's flip criterion, and `homelab#876` was later wired as its native blocked-by.

**Mechanism.** `agents/coordinator/README.md` already documents the exact reconciler for the sibling state — the deterministic scan REMOVES `agent/in-progress` when there is *"no live pod, no open PR, no merged PR mentioning it, persisted past `C4C5_PERSIST_S`"* (IL-T16, `homelab#155`) and restores `agent/queued`. `agent/review` has the same phantom mode (PR closed unmerged) and no such predicate — and unlike `agent/blocked`, it is not a human gate, so nothing is meant to hold it. Falsify by finding an `agent/review` issue with no open PR that the scan re-queued on its own.

**Process change.** Extend the phantom predicate already written on the `agent/in-progress` row in `agents/coordinator/README.md` to `agent/review`, verbatim shape: no live pod, no open PR, no merged PR mentioning it, persisted past `C4C5_PERSIST_S` → restore `agent/queued`.

**Expected saving.** 18h56m of zero motion on the one in-window instance, plus the goal-flip and blocked-by chain it held. Same shape as `homelab#405` (*"`agent-fix` without an `agent/*` state is invisible to every scan class"*), already closed — this is its unguarded sibling.

---

### F6 — Budget tier and calibration are emitted only when a human sets the override label, so cap sizing is unmeasurable on the stack where the 403s happen

**Evidence.** `budget_tier` is non-null on **6 of 40** rows — sleep-tracking 3/3, circles 3/7, and **0 of 25 homelab, 0 of 5 oracle-fleet**. A repo-wide search for `label:agent-budget/xs,sm,md,lg` on `teststuffstash/homelab` returns **0 issues, ever**. Both `budget-exhausted` events in this window sit in tier-null rows: `homelab#778` r4 (`poolside/laguna-s-2.1:free`, `budget-403`) and `homelab#779` r1 (`deepseek/deepseek-v4-flash`, `budget-403`, then swapped to haiku). Where tiers *are* recorded, all four `lg` rows spent \$0.18–\$0.74 against a \$2.00 cap (`calibration_error` 0.091–0.370) and the single `sm` row is the worst in the set (0.544) and terminated blocked.

**Mechanism.** `agents/coordinator/README.md` defines `agent-budget/{xs,sm,md,lg}` as an *"optional cap-tier override for the estimator"* set by a human. The ledger's `budget_tier`/`budget_cap_usd`/`calibration_error` triple tracks that **override label**, not `estimate_budget.py`'s own `pick_tier` output — so on a stack where the label is never used, the estimator runs and its calibration is simply never recorded. Falsify by finding a homelab ledger row with a non-null `budget_tier` and no `agent-budget/*` label.

**Process change.** In `agents/estimate_budget.py`, have the `--emit-cr` path also emit its own `pick_tier` result and point estimate into the row the ledger consumes, so `calibration_error` is computed on every capped ride rather than only overridden ones.

**Expected saving.** No compute. It makes cap calibration measurable on 30 more rows and is the precondition for scoring r3 F5's `1.5 → 2.0` headroom change — which was made for exactly the failure mode (a run dying on `403 Key limit exceeded` at a tier edge) that occurred twice this window, both times in the blind set.

## Proposed process changes

| change | artifact | expected saving | confidence |
|---|---|---|---|
| A fleet ruling files ONE `agent-fix` + `agent/queued` issue naming the gate that did not fire, and links it — filed, not asked | `agents/coordinator/README.md`, STRIKE-channel sibling clause on the `agent/error` row | 9 of 15 strikes on 2026-08-19 (~2 min pod spin-up each, guaranteed fail) + 9 round-1 restarts; untreated tail forecast at ~24 days | **High** — within-window controlled contrast: the filed half of the same ruling landed in 1h09m (#629→PR#643); the asked half never did |
| Add a `DELIM-FIELD` signature: unanchored `grep -F`/`-m1 "$var<delim>"` against a delimited table, and `read` over tab-delimited fields with an optional-empty field | `scripts/prompt-transport-lint.py` (new signature beside `HEREDOC-FN-DOLLAR`) | 4 of 25 blocking rounds; all 3 of PR#863's | **High** — the artifact's own docstring states the add-after-incident method; `homelab#734` is the precedent |
| Blocking: a NEW replay world / `expected/actions.txt` row / `agents/*-test.sh` pin that does not fail against pre-fix source; PR body shows the red run | `.agents/review.md` §BLOCKING (CODEOWNERS-gated → flag in PR) | 5 of 25 blocking rounds; on PR#858/#863 it is the ceiling-consuming third round | **High** — 5 in-window blocks + 4 self-filed issues (#690, #830, #851, #914); the rubric's "additive rows are ordinary work" is the exact loophole |
| A pattern fix must enumerate the sibling sites of the changed predicate in the PR body and say why the rest need no change | `.agents/fix.yaml`, PR-body requirements block (beside the `Fixes #{{ issue }}` line, :100) | 6 of 25 blocking rounds | Med-High — 6 independent instances across 6 PRs; relies on author compliance, not a lint |
| Extend the IL-T16 phantom predicate (no live pod / no open PR / no merged PR mentioning it / past `C4C5_PERSIST_S`) from `agent/in-progress` to `agent/review` → restore `agent/queued` | `agents/coordinator/README.md`, `agent/in-progress` + `agent/review` state-machine rows | 18h56m of dead time on `homelab#778`; unblocks a goal flip criterion | Med-High — shape is already installed and proven for the sibling state; n=1 in-window instance |
| `--emit-cr` also emits `pick_tier`'s own tier + point estimate into the ledger row, not only the human `agent-budget/*` override | `agents/estimate_budget.py` | no compute; makes cap calibration measurable on 30 of 40 rows and lets r3 F5's ×2.0 headroom be scored where the 403s actually occur | **High** — 0/25 homelab rows carry a tier and 0 `agent-budget/*` labels exist; both budget-403s are in the blind set |

**No issues were filed by this session.** Per the output contract, the intended parents are: F1 → `homelab#625` (origin row, where the 15:04Z ruling lives); F5 → `homelab#778` (origin row); F6 → standalone-honest (aggregates 34 tier-null rows across two stacks); F2, F3, F4 → standalone-honest (each aggregates 4–9 rows across 6+ PRs).

## Task granularity (per deep-dive task)

| # | task | verdict | evidence |
|---|---|---|---|
| 1 | homelab#625 | **chunked-right** | One deliverable (absorb exit-3 in the dispatch leg). 3 reviewer verdicts, each a *new* defect introduced by the prior round's own fix (r1 `grep -m1` drain → r2 a new `while` silently repointing an existing `continue` into an unbounded loop → APPROVED). Zero cross-chunk friction; the one wasted attempt is F1's rail fault, not scope. 13 commits, 8 of them `Merge branch 'master'`. |
| 2 | oracle-fleet#1 | **unverifiable** | `teststuffstash/oracle-fleet` 404s under both the default and fleet tokens. Ledger only: 4 attempts, legacy integer `rounds` shape, `wall_time_s` 13,762 with `queue_wait_s` and `active_run_s` both absent, \$0.248. r4 judged it chunked-right; no new evidence either way. |
| 3 | sleep-tracking#71 | **unverifiable** | `teststuffstash/sleep-tracking` 404s under both tokens. Ledger only: 3 attempts on 3 *different* models (`ling-3.0-flash:free` → `laguna-s-2.1` → `hy3`), `failed`/`failed`/`blocked-deliberate`, the worst calibration in the whole set (0.544 against an `sm` \$0.50 cap), and `active_run_s` 11,733 > `wall_time_s` 10,055. |
| 4 | homelab#778 | **should-have-been-one — the fan-out actively cost more than it saved** | The operator-directed 4-arm fan-out pilot: 4 worker pods spawned within 4 seconds, **3 permanently `Unschedulable`**, wedging the whole homelab worker lane; the FU-069 runaway-dispatch breaker fired at 14:15Z and was hand-cleared at 14:33Z. The comparison was seat-driven (*"pick the survivor whole (no code weaving)"*), one arm survived (PR#794), and PR#790 was closed with its deliverable explicitly returned *"via the NORMAL worker flow"* — i.e. three arms produced re-queued work plus a lane wedge. Then 18h56m in the F5 sink, then a further split on 2026-08-24 (deliverable 2 → FU-181). The issue's own re-scope note records that the original body *"duplicated shipped work"*. Cross-chunk friction: total. |
| 5 | homelab#791 | **chunked-right** | One deliverable (the `or_leg` translation). The one non-productive attempt was a `goose-32602-truncation` harness death — a strike, not scope. Both blocking verdicts were credential-guard defects in the round's own new code (r2 introduced a *new* one in the very guard meant to fix r1). Correctly *did not* widen: the residue was filed as siblings #826, #852, #869, #827 rather than absorbed. |
| 6 | homelab#876 | **chunked-right, and the recipe earned its keep** | Carved out of #854 *"with a footprint that touches no `pin-only-lint` GUARDED path so it can actually ride"* — granularity chosen against the gate, deliberately. Round 1 was dispatched onto the suspect rail *on purpose* (*"per the strike protocol"*), reproduced the fault on the first try, and the worker ruled `AGENT_INFEASIBLE: opencode.ai backend/session service` in a sub-minute exit that the scan parked — the r3 F4 path working end to end. |
| 7 | homelab#270 | **chunked-right — still the model run** | r4 called it: explicitly scoped as *"the half PR #267 deliberately left unshipped"*, 2 clean rounds, PR#275 open→merge in 2,578s, zero blocking verdicts. New datum from this ledger: it is one of the 7 reachable rows that are CLOSED on live GitHub yet still wear `agent/blocked`. |
| 8 | oracle-fleet#225 | **unverifiable** | Repo 404s under both tokens. Ledger only: 1 attempt, `clean`, `ci: true`, `wall_time_s` 0 with `active_run_s` 2,331, \$0.1666, PR#256. r4 judged it chunked-wrong (four lanes in one issue); I could not re-check. |

## Wins to codify

1. **Separate the observed evidence from the hypothesis, and state acceptance behaviourally.** `homelab#648` is the fastest clean run in the platform window — PR#651 open→merge **534s**, one review, `APPROVED`, zero blocking rounds, `active_run_s` 679. Its issue body does three things: timestamps the observation with the metric that shows it (*"the whole family absent 17:47→18:17"*), labels the cause *"Leading hypothesis (unverified, marked as such)"*, and then writes *"Whatever the exact mechanism, the acceptance is behavioral."* The round was therefore free to find the real mechanism (`collect_job_timings` serialized over a 24h cold backfill) instead of defending the filer's guess, and the reviewer approved on the first read. The exact inverse is PR#862, blocked with *"the diagnosis is refuted by live evidence, and this fix would not resurrect the scout."* Codify as one line in `.agents/fix.yaml`'s issue-reading step: *a hypothesis in the issue body marked unverified is a lead, not a requirement — meet the behavioural acceptance and say plainly if the mechanism differed.*
2. **Scope to an already-written design section and nothing else.** `homelab#781`/PR#801: zero blocking rounds, both approvals first-pass, merged in 3,006s. The reviewer's approval states why: *"this is §M10's own prescribed end state (deliberately NOT reusing audit/research, per that section's warning)."* Same family as r4's Win-1 (`homelab#270` completing a merged finding's unshipped half). The reusable move is that the issue names the spec section that already decided the design, so the round spends nothing deciding it.
3. **Named so it is not re-proposed — and flagged as unverifiable.** r4's Win-3 recorded the r3 red-first rule as landed at `.agents/fix.yaml:39-40` (*"commit it RED first, then fix — so re-review verifies an executable pin, not a claim"*). It is **not in the file today**: grep over all 165 lines for `RED` / `red→green` / `executable pin` returns 0 hits, and the cited commit `8bc4ecb` does not resolve in this repo (HTTP 422). I am not claiming it was removed — I cannot see the history. But F3 exists because nothing enforces it now.

## Platform KPIs (ADR-103)

**(1) Bucket-A — 28 events, window 2026-08-18 → 2026-08-25.** Same rule as r3/r4 (coordinator / review-reflex / prompt-launcher / scan / loop-state-misclassification defects filed as platform-repo issues; excluding pure infra 🚨 alerts, feature build-out, docs-drift-only, and stint/goal/post-launch containers). Counted as **distinct fault events**, so an explicit sprout chain counts once — this is what keeps the number at 28 rather than 36 raw issues.
- *scan* (11): #501 (footprint holds vs issue-label lifecycle disagree), #595+#602 (merge-conflict clause: neither `WORKER_AUTHOR`-scoped nor state-fp debounced; null-author PR falls out of both), #625 (exit-3 refusal reds the workflow), #607/#622/#630/#635 (the agent-summary marker read as an unanchored substring, four readers, one shape), #730+#731 (unbound-sprout belt, false negative and false positive), #822+#828 (goal-decompose units footprint-held, then rejected by the doorbell fast-path), #829 (queued units starved by a self-regenerating changes-requested stream), #849 (`REPO_PR_CAP` base-blind), #853+#875 (ratchet clause list drifted from ci.yaml; the tab-IFS comment stale at "two" when it is four), #868 (arbitrate churn on a landing PR)
- *coordinator / launcher* (10): #617 (session rides blind on `/loop-git-token` failure), #629/#660/#674/#687/#690 (the AGENT_STRIKE attribution + 429-classifier chain), #866 (a harness death on a ride that already has a PR emits no strike), #871 (`budget-403` is not only budget — a fresh `xs` key 403'd at \$0.0069), #804 (opencode startup config death), #876 (opencode `UnknownError` ride death), #810 (explicit `--model` no longer overrides the route), #861 (retro cells ride the routed model, not their configured cell), #509 (a TERMINAL goal gates its descendants forever), #807 (goal budget gate freezes trees on a slow ledger read)
- *prompt / launcher transport* (1): #564+#734 (two unguarded `prompt-transport-lint` signatures)
- *review reflex / reviewer* (4): #556 (a DISMISSED own verdict is not a verdict at head — dispatch-refuse loop), #560 (a reviewer pod with no verdict, no aside and no breaker reports Succeeded), #652 (re-review edge gap, ~25 min pickable), #888 (FU-147 arbitration probe matches `ARBITRATE` unanchored)
- *loop-state misclassification* (2): #515 (requested≠served drift belt blind for 23 rides), #686 (false `THROUGHPUT-STALL` while rides merge), #748+#752 (`model_drift_rows()` counts known-failed rides as unverifiable)

**(2) Trend — it did NOT fall.** r4 strict (2026-08-10 → 08-17): **15** of 106 platform issues. This week: **28** of 188. Absolute **+87%**; share **14.2% → 14.9%**, i.e. flat against a 77% larger filing week. Two honest caveats: my clustering rule is a judgment call and a stricter reading (counting only the top-level issue of each cluster) gives 22; and the responder lane, which r4 reported only as a "wide" variant, is excluded here for comparability. Per ADR-103 this is **one** week of non-fall, not yet the sustained non-fall that triggers revisiting label-carried loop state — but F5 is precisely a label-carried-state defect, so the trigger is worth watching next run.

**(3) Proposed next gate — `agents/replay/fixtures/pin-vacuity-<clause>/`, a fixture that must fail against pre-fix source.** The highest-recurrence unguarded class this week is **the ratchet's own blind spot**: a new, additive pin that passes both before and after the diff. Nine events, one shape — 5 blocking review rounds (PR#631 r1, PR#626 r2, PR#863 r1, PR#858 r3, PR#786 r3) and 4 self-filed issues (#690, #830, #851, #914). The recorded world is one clause change shipped with a fixture whose `expected/actions.txt` is identical against pre-fix and post-fix source; expected outcome = `clause-replay` FAILS the PR. `scripts/merge-path-lint.py`'s ADR-103 orphan gate supplies the ratchet, and F3's `.agents/review.md` bullet is its human-side pair.

**Note on r4's proposed gate:** `lane-membership-quoted-inert` was r4's mandatory next gate. It is **not among the 85 fixtures in `agents/replay/fixtures/`** today, and its class recurred four times this week (#630, #635, #888, PR#863 r1). It remains the correct second gate.

**(4) Jail \$/day — not a retro input** (homelab#587), and not computed here.

## Predecessor score

r4 (2026-08-17, oracle stack) is the immediate predecessor; three of its six changes have merged, and I scored them against live artifacts and the ledger rather than rounds/issue — mean attempts/issue is 2.40 pre-r4 (n=5) vs 3.41 post-r4 (n=32), but the pre-r4 sample is five older-format rows from a different stack, so **that comparison is not sound and I am not drawing a conclusion from it.**

- **r4 F2 — strike-side fleet trigger: MERGED and EXERCISED.** The clause is live in `agents/coordinator/README.md` (*"§One fleet fault, retro r4 F2"*, quoted in this brief's own excerpt) and fired twice on 2026-08-19, correctly, with the mechanism named and `agent/error` labels correctly withheld. It did what it was designed to do. F1 is the gap it exposed downstream, not a failure of the change.
- **r4 F3 / r3 F4 — the `AGENT_INFEASIBLE` recipe half: MERGED and EXERCISED.** Present at `.agents/fix.yaml:115-123`, tagged *"(retro r3 F4)"*. First platform use I can find: `homelab#876`, 2026-08-24T18:50:59Z — the worker posted the marker, the scan parked the issue with *"That is a VERDICT, not a crash, so it does not go back through `c4c5-redispatch`: re-riding it would spend another paid session to re-derive an answer the loop already has."* One paid session saved, measurably.
- **r4 F4 — emitter emits `rounds: [{model, exit_status, error_class, ci}]`: MERGED.** 35 of 40 rows carry the structured shape; the 5 legacy-integer rows are all pre-2026-07-30 (`oracle-fleet#1`, `#66`, `sleep-tracking#43`, `#48`, `#71`). This is the single most useful change in the set — every per-model and per-error-class number in this report comes from it, and r4 could not compute them at all.
- **r4 F1 — conditional `Fixes #{{ issue }}`: NOT LANDED.** `.agents/fix.yaml:100` still reads *"The PR body must CLOSE the issue: write `Fixes #{{ issue }}`"*, unconditional, with no `Refs #` alternative.
- **r4 F5 — `snapshot: true` on mid-flight rows: NOT LANDED,** and the proposed fix would not have been sufficient. No row carries a `snapshot` field. More importantly, r4's predicate was *"emit `snapshot: true` whenever `issue_state` is OPEN"* — but the staleness is on **live GitHub, not in the emitter**: of the 10 reachable `agent/blocked` rows, **9 are CLOSED** and **7 still wear the `agent/blocked` label** (`homelab#625` — PR#631 merged; `#270`, `#148`, `#375`, `#329`, `#292`, `circles#77`). Only `homelab#778` is genuinely open-and-blocked. All 7 have `issue_state: CLOSED`, so r4's OPEN-only predicate would have flagged none of them. Three of them (`#375`, `#329`, `#292`) rank 13/14/15 of 40 with **zero rounds, zero wall-time and zero cost** — the pain-rank is ranking stale labels above real work.
- **r4's mandatory next gate (`lane-membership-quoted-inert`): NOT LANDED,** and its class recurred 4× this week — see KPI (3).

## Evidence confidence

**Ledger blind spots** (`reviewer_rounds`, undecomposed `wall_time_s`, harness-only `retry_storms`, `$0.00` = untracked) are taken as briefed. I counted review rounds from PR verdicts throughout — the field disagreed with the trail on 13 of 20 platform PRs, in both directions.

**Could not verify:**
- **Deep-dive ranks 2, 3 and 8** (`oracle-fleet#1`, `sleep-tracking#71`, `oracle-fleet#225`) — 37.5% of the deep-dive set. `teststuffstash/oracle-fleet` and `teststuffstash/sleep-tracking` return HTTP 404 under **both** the pod's default token and `RETRO_GH_TOKEN`; `installation/repositories` for the fleet token lists only `teststuffstash/openrouter-operator`. `homelab` and `circles` are reachable under both. Those three tasks are scored from ledger fields alone and are marked unverifiable in the granularity table.
- **The responder-ledger half of the bucket-A count.** Bucket-A is counted from platform-repo issues only. The pushgateway DNS name does not resolve from this pod, no `aws` CLI is present for `s3://agent-transcripts/`, and `kubectl` authenticates as `system:serviceaccount:openrouter-operator:agentstack-worker` (`pods is forbidden ... in the namespace "homelab"`). r4 had the same limitation, so the 15 → 28 comparison is at least like-for-like.
- **Whether the r3 red-first clause was ever in `.agents/fix.yaml`.** It is absent today and r4's cited SHA `8bc4ecb` does not resolve; I have no history access to distinguish removal from mis-citation.
- **Whether wall-time outliers outside homelab are review latency.** Fleet-wide, 111h of 144h wall (77%) is neither `queue_wait_s` nor `active_run_s`, concentrated in `circles#77` (32.1h unaccounted), `oracle-fleet#194` (21.7h) and `sleep-tracking#48` (20.6h). I verified the mechanism only for circles: PR#79 waited **32h29m** for its first verdict, which was an immediate `APPROVED` — pure review-queue latency, zero rework; PR#45 and PR#58 show 11h34m and 6h12m to first verdict. The oracle and sleep rows are unreachable. **The platform stack is not the tail** — median time-to-first-blocking-verdict across 20 homelab PRs is 1,559s (26 min), max 5,173s (86 min). The one platform outlier, PR#836 at 13.3h open→merge, is a **human codeowner** gate: the bot approved at 22:13:52Z, the codeowner at 10:10:37Z the next morning, with 10 update-merge commits accumulating in between. Related: 82 of 128 commits (64%) across the 10 most-reviewed platform PRs are `Merge branch 'master' into …`; `#868` (closed) and `#887` (open) already track that churn, so I did not make it a finding.

TOOL_GAP: gh api repos/teststuffstash/{oracle-fleet,sleep-tracking} — needed for deep-dive ranks 2, 3 and 8; 404 under both the default token and RETRO_GH_TOKEN.
TOOL_GAP: responder ledger (pushgateway/s3 read) — needed for the responder-lane half of the ADR-103 bucket-A count; pushgateway DNS unresolvable, no aws CLI, kubectl namespace-scoped away from homelab.
