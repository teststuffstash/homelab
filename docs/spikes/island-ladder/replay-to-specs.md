# Replay to specs — the migration map

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca`, 2026-11-22.

## How the migration works

- **A replay family** is a set of fixtures under `agents/replay/fixtures/` that pins one clause of an
  old member: a recorded world in, an expected action stream out
  ([agents/replay/README.md](../../../agents/replay/README.md)). A family is either N fixture
  directories (actions mode), one `rows.psv` decision table (table mode), or a registered test script
  (suite mode). The fixture-to-family map is [families.tsv](../../../agents/replay/families.tsv); the
  generated index in the README (`run.sh --index --write`) names each fixture's old member (`source`).
  The required `ci` check runs every family on every push (`.github/workflows/ci.yaml`, step
  "Clause replays").
- **Rows are the test source** ([islands/README.md](../../../islands/README.md) §Built from the specs,
  rule 1): each requirement row on an island's spec page becomes one `rule()`-labelled case, its inputs
  and expected cells taken from the page, run over a recorded world (rule 2). The page row keeps the
  replay row id as its description, so the two can be joined.
- **A ruled comparison** (rule 4): the family runs against the old member and the new component; every
  difference gets a committed ruling `spec`, `old` or `new`. An unruled difference blocks; equality is
  not the acceptance. The only implementation is scan's
  [compare.py](../../../islands/scan/tests/compare.py), with one rulings file per family under
  `islands/scan/tests/comparison/`.
- **When a family can be retired: no written rule.** No file under `islands/`, `agents/replay/` or
  `docs/intake/` says when a family may be deleted. The intake facts files say only that retiring an
  old member is a `seat` switch-over change
  ([docs/intake/scan.md](../../../docs/intake/scan.md) §Switch-over; same text in `launch.md`,
  `retro.md`). The one precedent is `scout-bench/*`, deleted together with its member
  `model-scout.sh` (replay README, cleanup move 6).

## The map

Counting units (commands in the footnote): a **family** is the first path segment of the generated
index (271); a **fixture** is one index row, which is one `fixture.yaml` (521); a **case** is an
actions or suite fixture, or one table row (1071). "On a page" means a contract page under
`islands/<island>/specs/` (not its README) names the family.

| Family (group) | Fam. | Fixtures | Cases | Old member | Island | State | Evidence |
|---|---|---|---|---|---|---|---|
| `updater` | 1 | 1 | 43 | `update-pr-branch.sh` | scan | compared and ruled: 28 equal, 15 ruled `old` | `comparison/updater.rulings`; `test_updater.py` over world `pr-board`; Goal #3490 (open), PR #3561 (merged) |
| `major-handoff` | 1 | 1 | 15 | `major-handoff.sh` | scan | compared and ruled: 15 of 15 equal | `comparison/major-handoff.rulings` (empty); `test_major_handoff.py` over world `pr-handoff` |
| `fu124-nudge` | 1 | 1 | 11 | `coordinator-scan.sh` | scan | rows on a spec page | named as a comparison on SCAN-UPDATER-RENOVATE; no entry in `compare.py` |
| `arbitrate`, `unarmed-major`, `changes-requested*`, `merge-conflict` | 5 | 65 | 69 | `coordinator-scan.sh` (`changes-requested-body-edit`: `review-reflex.sh`) | scan | rows on a spec page; `changes-requested-body-edit` claimed by glob only | SCAN-CLAUSE-PR, 🚧 → #3448 (open) |
| `ci-red-*` | 8 | 11 | 31 | `coordinator-scan.sh` | scan | 2 on a page, 6 claimed by glob only | SCAN-CLAUSE-PR, #3448 |
| `c4c5-*`, phantom/flip belts | 9 | 10 | 36 | `coordinator-scan.sh` | scan | 4 on a page, 5 by glob or index only | SCAN-CLAUSE-PHANTOM, #3448 |
| `fleet-*` | 10 | 10 | 21 | `coordinator-scan.sh` | scan | 7 on a page, 3 by glob only | SCAN-CLAUSE-FLEET, #3448 |
| goal lane (`goal`, `goal-checkpoint-*`, `harvest`, `merged-closeout-*`, `fu143-goal-child-closeout`, `assembly-cr-*`) | 14 | 14 | 66 | `coordinator-scan.sh` | scan | 3 on a page, 11 by glob or index only | SCAN-CLAUSE-GOAL, #3448 |
| `goal-ancestor`, `goal-budget-gate`, `goal-budget-refusal` | 3 | 3 | 22 | `agent-session.sh` | scan **and** launch | rows on launch's page (LAUNCH-PREFLIGHT-GOAL-BUDGET); scan's page names `goal-ancestor`, its index `goal-budget-gate`, its README glob `goal*` all three | double claim, unresolved |
| queued + body grammar (`queued-*`, `blocked-*`, `body-block-malformed`, `touches-malformed`, `issue-body`, `clause-coverage`, …) | 12 | 15 | 23 | `coordinator-scan.sh` | scan | 10 on a page, 2 index only | SCAN-CLAUSE-QUEUED, SCAN-GH-BODY, #3448 |
| holds + footprint (`scan-guarded`, `scan-governance`, `footprint-*`, `pr-cap-per-base`, `session-belt`, `live-worker-pod`, …) | 11 | 19 | 52 | `coordinator-scan.sh`, `touches-check.sh`, `kube.sh` | scan | 8 on a page, 3 index only | SCAN-HOLD-*, #3448 |
| wake + fast path (`doorbell`, `unit-fast-path-*`, `fu143-fast-path-goal-head`) | 4 | 11 | 12 | `coordinator-scan.sh` | scan | rows on a spec page | SCAN-WAKE-*, #3448 |
| `scan-lane-walk`, `state-fp`, `unowned-pr-backstop` | 3 | 5 | 8 | `coordinator-scan.sh` | scan | rows on a spec page | SCAN-LANE-WALK, SCAN-CLAUSE-DEBOUNCE |
| dispatch arm (`dispatch-phase`, `fu146-*`, `coordinator-*`, `session-atomic-gate`) | 10 | 15 | 29 | `coordinator-session.sh`, `coordinator-scan.sh` | scan | 9 on a page, 1 index only | SCAN-DISPATCH-*, no issue on the status |
| review reflex (`review-pick`, `reflex-*`, `c9-rearm`, `decorrelate-resolution`, `slo-teeth`, `reviewer-optout`, …) | 8 | 21 | 30 | `review-reflex.sh` | scan | rows on a spec page | SCAN-REFLEX-*, no issue on the status |
| signals (`scan-phase-marker`, `scan-wedge-alert`, `item-class*`) | 4 | 4 | 4 | `coordinator-scan.sh` | scan | rows on a spec page | SCAN-SIGNAL-* |
| `gateway-admit` | 1 | 1 | 12 | `gateway-admit.sh` | launch | rows proven as rule-labelled cases, but the case list is the replay `rows.psv`, the target is a bash helper, and nothing compares it with the old member | `islands/launch/tests/test_admit_rows.py`; Goal #3390 (open), #3393 (closed) |
| `gateway-sessions`, `gateway-env-pull`, `gateway-outcome` | 3 | 3 | 44 | `agent-session.sh` | launch | rows on a spec page | admission.md, pod.md, outcome.md |
| preflight + arming (`argv-max-turns`, `base-arm-*`, `major-arm-guard-*`, `preflight-malformed-block`, `fu042-*`) | 13 | 13 | 18 | `agent-session.sh` | launch | rows on a spec page | dispatch.md |
| context + card (`context-prefetch*`, `ci-failure-run-select`, `pf-cm-init`, `env-card-*`, `specs-process`, …) | 12 | 34 | 35 | `agent-session.sh` | launch | rows on a spec page | context.md |
| pod + harness (`harness-run-cmd`, `harness-enforce-default`, `cred-inject-unconditional`) | 3 | 22 | 22 | `agent-session.sh`; 6 of the 14 `harness-run-cmd` fixtures source `re-review.sh` | launch | rows on a spec page | pod.md |
| outcome + strikes + old routing (`strike-*`, `router-report-*`, `go-rail-latch`, `fu088-ladder`, `route-request`, `model-id-carrier`, `dead-ride-record`, `run-phase-metric`, `pick-rail`, `rail-degrade`) | 15 | 18 | 99 | `agent-session.sh`, `subscription-latch.sh`; `dead-ride-record` sources `coordinator-scan.sh` | launch | rows on a spec page | outcome.md, admission.md (⚑ gap rows for the old proxy) |
| unspecced launcher clauses (`image-volumes`, `opencode-*`, `nix-registry-env`, `python-profile-env`, `ride-size`, `transcript-mirror-probe`, `post-merge-push`, `context-repos-prelude`, `resolve-model`) | 10 | 19 | 30 | `agent-session.sh`, `resolve-model.sh` | launch (README list only) | not started | [launch README](../../../islands/launch/README.md) §Open "Unspecced clauses" |
| `argv-payload`, `retro-gh-token-env`, `retro-pg-env` | 3 | 8 | 9 | `agent-session.sh`, `retro-session.sh` | launch and retro (shared; code is launch's) | not started | on no page; retro README "fixtures it shares" |
| `retro-quiet-guard` | 1 | 1 | 10 | `retro-argo.yaml` | retro | 5 of 10 rows proven as rule-labelled cases; old and new verdicts asserted equal; no rulings file | `islands/retro/tests/test_guard_expr.py` (RETRO-GUARD-EXPR) |
| `retro-cell-report` | 1 | 5 | 5 | `retro-argo.yaml` (`retro-report-floor.sh`) | retro | 5 of 5 proven as rule-labelled cases; old and new asserted equal; no rulings file | `islands/retro/tests/test_report_floor.py` (RETRO-REPORT-FLOOR) |
| other retro (`retro-gateway-cell`, `retro-key`, `retro-harvest`, `retro-harvest-push`, `retro-push-belt`, `retro-activity-window`, `retro-rank-snapshot-exclusion`) | 7 | 11 | 33 | `retro-session.sh`, `retro-argo.yaml`, suites | retro | rows on a spec page | cell.md, harvest.md, guard.md, activity.md |
| 9 unclaimed groups | 98 | 180 | 282 | see §Unclaimed families | unclaimed | not started | — |

No family is retired. `gateway/` claims none: `gateway/README.md` has no `replay` match, and the old
router it replaced (`argocd/resources/openrouter-proxy/`) has no replay family.

## Totals

| Island | Families | Fixtures | Cases | Compared and ruled | Rows proven as cases | Rows on a page | Claimed, not on a page |
|---|---|---|---|---|---|---|---|
| scan | 101 | 203 | 450 | 2 fam. / 58 cases | (the same 2) | 67 fam. | 32 fam. |
| launch | 57 | 110 | 260 | 0 | 1 fam. / 12 cases | 46 fam. | 10 fam. |
| retro | 9 | 17 | 48 | 0 | 2 fam. / 10 cases (equality, no rulings) | 7 fam. | 0 |
| shared (scan+launch, launch+retro) | 6 | 11 | 31 | 0 | 0 | 3 fam. (on launch's page) | 3 fam. |
| unclaimed | 98 | 180 | 282 | — | — | — | — |
| **all** | **271** | **521** | **1071** | **2 / 58** | **5 / 80** | | |

The state columns are exclusive: a family counts once, in its furthest state. About 5% of cases (58 of 1071) sit in a ruled comparison; 26% (282) belong to no island.

## Unclaimed families

Grouped by the old member they test. The island column is my reading, not a decision.

| Old member | Families (fixtures / cases) | Most plausible owner (reading) |
|---|---|---|
| `reviewer-session.sh`, `specs-reviewer-session.sh`, reviewer lenses (`reviewer-*` ×13, `tool-gap-surfaces`, `specs-review-body-edit`, `issue-derivation`, `asvs`, `lens-posture`, `loop-fetch-guard`) | 19 (41 / 75) | review, not started (`islands/README.md` "Not started"); also the 6 `re-review.sh` fixtures launch claims inside `harness-run-cmd` |
| `responder-argo.yaml` (`responder-*`) | 12 (48 / 48) | the fresh intake build (responder) |
| `fix-debounce-argo.yaml` (`fix-debounce`, `fix-debounce-setpass-admit`) | 2 (2 / 19) | the fresh intake build — scan README calls it "the responder/intake piece" |
| `deploy-revert-argo.yaml` (`deploy-revert-*`, `tofu-image-revert-*`, `tofu-provider-revert-*`, `workflow-pin-revert-*`) | 27 (30 / 44) | no planned island; scan README: "the revert guard", not a member |
| `coordinator-scan.sh` / `coordinator-session.sh` clauses no page names (`assembly-ci-red`, `stale-armed-retry`, `renovate-rebase-tick-*`, `sprout-report-*`, `stale-stamp-repair-*`, `adopted-not-queued-surfaces`, `body-footprint-mismatch`, `parity-assertion-sigpipe`, `janitor-run-cmd-surfaces`, `ci-cause-grammar`, `touches-check-predicate`) | 16 (29 / 41) | scan — same old members it already claims |
| `agent-session.sh` (`docker-paths`, `opencode-phonehome-killswitch`, `model-id-parse-drift`, `budget-label-floors`) | 4 (8 / 11) | launch |
| `retro-session.sh` (`retro-series-identity`) | 1 (2 / 2) | retro |
| other members: `research-fanout.sh` (2), `board.sh` (2), `images.env` (2), `corpus-dispatch-argo.yaml`, the AgentStack Composition (`probe-parent-admit`), `epic_dispositions.py`, `ledger.py` (`ledger-emitter-rounds`), `machine-comment.sh` (`summary-comment`) | 11 (11 / 29) | no planned island; the Composition is the claim island scan README names; `ledger.py` is shared observability (retro README "Not members") |
| the harness itself (`_selftest`, `gh-json-fields`, `hermeticity-audit`, `sigpipe-lint`, `label-write-lint`, `clause-replay-pairing`) | 6 (9 / 13) | none — they test the replay harness or repo-wide lints and go when the harness goes |

Some families should retire with their old member instead of being compared, per the pages' own `⚑ gap`
rows (my reading; numbers are cases): the old-proxy routing families `pick-rail` (3), `resolve-model` (9),
`rail-degrade` (1), `go-rail-latch` (15), `route-request` (2), `router-report-*` (4),
`coordinator-pick-rail` (5); `retro-key` (5, "deleted with the old proxy", RETRO-CELL-KEY); and
`retro-rank-snapshot-exclusion` (no live caller, RETRO-RANK-LEGACY).

## What blocks retirement

| Condition | State |
|---|---|
| A written rule for when a family may be deleted | **done nowhere**; nothing filed |
| A ruled comparison for the family | done for 2 families (scan); retro asserts equality without a rulings path; launch has none |
| The island suite in the required `ci` check | **done nowhere**: #3391 open, PR #3627 open. Today scan and launch suites run at the worker's `pr-open` via `scripts/diff-ci.sh`; scan's suite also runs inside the CI "Scan specs site publish" step, which does not fail on a red suite |
| Switch-over: live callers read the new component | **done nowhere**: nothing live reads `islands/` (islands/README.md); a `seat` change per island, nothing filed |
| The old member retired | **done nowhere**. While it lives, the ADR-103 ratchet ties every edit of a clause file to a replay change (replay README §When a clause file changes) and CI runs the family |
| The island's own tests no longer read the family | **done nowhere**. Scan's `compare.py` and `test_replay_adapter.py` run the old side through `agents/replay/` stubs and fixtures (`diff-ci.sh` re-runs scan's suite when `fixtures/updater/` or `fixtures/major-handoff/` change). Launch's 12 cases read `fixtures/gateway-admit/rows.psv` as their row list, so they die with the family. Retro's `conftest.py` runs `run.sh` as its oracle |
| Evidence the specs reviewer can read | done nowhere: no tests root is declared for island roots and no spec gate or join ratchet reads them (islands/README.md §What every island shares) |

## Order

1. **Land #3391 / PR #3627** (island suites in the required check). Every later step needs a red island
   suite to block a merge. Not a choice.
2. **Bring launch and retro onto rule 4 before they add families.** Launch's case list is the replay
   table and retro asserts equality; both differ from rule 1 and rule 4. Scan's `compare.py` and its
   rulings grammar are the piece to reuse. Real choice: widen scan first (#3448) or align the others
   first. Recommendation: align first, while each has one or two families; nothing filed for either.
3. **Resolve the double claims** (`goal-ancestor`, `goal-budget-*`; the `re-review.sh` part of
   `harness-run-cmd`; `dead-ride-record`, scan's member on launch's page). Nothing filed.
4. **Retire-with-member families need no comparison.** The old-proxy routing families and `retro-key`
   leave when the old proxy's last caller leaves. Recommendation: mark them so on their pages and skip
   them in comparison work.
5. **Write the retirement rule, then retire the first pair.** `updater` and `major-handoff` are the only
   families that could go, and only after a switch-over of `update-pr-branch.sh` and `major-handoff.sh`
   and after scan's comparison stops reading the deleted fixtures (frozen copy or recorded worlds only).
   Nothing filed.
6. **Then breadth, largest unclaimed first:** the review island (75 cases) and the fresh intake build
   (responder + fix-debounce, 67 cases). The revert guard (44 cases) and the "other members" group have
   no planned island; that is an operator call. Real choice: claim the unclaimed families before
   finishing scan's 32 claimed-not-on-a-page families, or after. Recommendation: after — a claim with no
   page row moves nothing.

## Not verified

- Counts come from these commands, run in the clone at `f1be04ca`:
  `sed -n '/replay-index:begin/,/replay-index:end/p' agents/replay/README.md | grep '^| \`'` (521 rows);
  `find agents/replay/fixtures -name fixture.yaml | wc -l` (521); table rows by counting
  non-comment, non-blank lines of each `rows.psv` under a `mode: table` fixture; claims by extracting
  backticked fixture names from each island's README replay list and its spec pages' fixture and
  comparison cells, with `x-*` and `x*` read as prefixes. A family the README names in prose without
  backticks would be missed.
- "On a page" is a substring match of the family name in a contract page; I did not check that every
  replay row of a family has a page row. One false hit corrected by hand: `ride-size` matches a pod
  label on `pod.md`, but the launch README lists ride size as unspecced, so it counts as not started.
- `families.tsv` has 177 mappings into 85 family names; the generated index groups differently (271
  first segments). I used the index; the two disagree on what a "family" is.
- I did not run any suite, so "28 equal, 15 ruled old" and "15 of 15 equal" rest on the rulings files
  (15 `old` lines; an empty file) and the brief, not on a run.
- The retro specs README still says the island has no `rule()` decorator; its tests directory has one.
  I took the files over the README.
- Goal #3389, #3390, #3391, #3448, #3490 and PR #3627 states were read with `gh` on 2026-11-22.
