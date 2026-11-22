# Launch — position on the island maturity ladder

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca`, 2026-11-22.

## What it is

The launch island will own the ride: dispatch params × recipe × claim → gateway admission →
context bundle → pod env → outcome ([islands/launch/README.md](../../../islands/launch/README.md)).
It replaces `agents/agent-session.sh` (the launcher, about 4 000 lines and 56 `REPLAY:` clauses) and
the helper `agents/gateway-admit.sh`, with `pr-open.sh`, `recipe-lint.sh`, `estimate_budget.py` and
`model_id.py` as further members. One piece exists: `islands/launch/lib/gateway-admit.sh`, a **shell**
admission helper (`gw_admit`, `gw_release`; `gw_admit_lane` not yet). Nothing live reads
`islands/launch/`; switch-over is a separate `seat` decision.

## Position

| Rung | State | Evidence | Open item |
|---|---|---|---|
| R1 Boundary | reached | README with "What this replaces", "Consumer contracts" (exposes 6, consumes 6), read set, revert class; facts file [docs/intake/launch.md](../../../docs/intake/launch.md) | nothing filed (final location is operator-only) |
| R2 Specs | reached | 7 contract pages + 7 sibling `*.schema.json`, 31 `### LAUNCH-` requirements (`grep -c`: dispatch 7, admission 4, pod 4, context 8, outcome 6, budget 2); RULES/CONVENTIONS pinned at v0.6.9 in [specs/README.md](../../../islands/launch/specs/README.md) | — |
| R3 Evidence | partial | `bash islands/launch/scripts/ci.sh` → `16 passed` (12 `rule()`-labelled cases + 4 unlabelled gate checks). The 12 cases are the 12 rows of `agents/replay/fixtures/gateway-admit/rows.psv` (`tests/test_admit_rows.py` reads the **fixture's** row list, not the page), labelled LAUNCH-ADMIT-HELPER (9) and LAUNCH-ADMIT-BOUND (3). 2 of 31 requirements have cases; raw Allure results only — no evidence pack, nothing rendered or published. Facts file count: 29 `🚧 WIP`, 2 `⚑ gap` alone | #3484 (rows from the page), #3390 (post-launch, open) |
| R4 Worlds | absent | `islands/launch/specs/worlds/` holds only `README.md` (an index of replay worlds). Its gateway-seam answers are hand-written ("not recorded from a live gateway"); one (`bound-dispatch`) sends `tier: strong`, which the supplier schema rejects (worlds README) | #3483 (gateway-seam worlds as whole files, schema-validated, strict reader) — `agent/blocked` |
| R5 Gates | partial | Suite runs at a ride's `pr-open` via `scripts/diff-ci.sh` row `-- bash islands/launch/scripts/ci.sh` (its comment: "GitHub CI has no step for it yet"). `grep -n "islands/launch" .github/workflows/ci.yaml` → no match. No spec gate, join ratchet or hygiene ratchet; specs reviewer reads rows under `extraSpecs` (#3379) with no evidence | #3391 / PR #3627 (open, review required; touches `ci.yaml` + `diff-ci.sh`); ratchets: nothing filed |
| R6 Replaces the old | partial | Families compared: 1 of the 42 family patterns in the README table (`gateway-admit`, 12 rows, all green against the island's shell helper; no ruling recorded because no difference). The helper is a shell rewrite (63 differing lines vs `agents/gateway-admit.sh` after whitespace strip, `diff | wc -l`), not a Python component (build rule 3). No caller switched; nothing retired | #3485 (ruled comparison vs a Python component), #3484 |
| R7 Metrics | absent | No gauges or alerts of its own; `intake-select.sh` line 350: "new islands: no alerts yet". The old member's `agent_run_phase_seconds` (LAUNCH-OUTCOME-PHASES, `argocd/resources/pushgateway/agent-runs.promtool-rules`) is the agent loop's | nothing filed |
| R8 Feedback loop | absent | Facts file: "a body on this island carries `Experiment: none`"; nothing deploys | nothing filed (needs R6 switch-over) |
| R9 Intake | partial | Selector row (`intake-select.sh` lines 329, 370, 407); the island-intake CronWorkflow walks every listed island (`agents/coordinator/island-intake-argo.yaml`, `island=all`). Intake comment on #3483 (2026-11-22) parks the second leg `blocked-on: human` (goal branch uncut). Facts file stale: "No tests root is declared and no evidence exists" while `tests/` runs 12 labelled cases | nothing filed |
| R10 Learns | absent | No launch-specific learning step; the shared wait/escape reads (`islands/intake/rules/intake-wait.md`, `intake-escape.md`) apply to any island. Whether any launch record reached the bar: not verified | nothing filed |

## Not on the draft ladder

- **Supplier contract consumption.** Launch is the consumer of the gateway's `POST /sessions`. Its
  gateway answers must validate against `gateway/specs/endpoints/sessions.schema.json` read in
  place. No rung covers "consumer worlds validated against the supplier's schema" (#3483 acc. 2).
- **Exposed-library contract.** `gateway-admit.sh` is sourced by 4 other launchers and 5 Argo manifests (README);
  switching it is a many-caller change unlike a single-entry island. No rung covers "exposed seam
  library parity" separately from R6.
- **Unspecced clauses.** README §Open lists clauses with fixtures and no page (ride size, nix/python
  env, hostAliases, argv ceiling, transcript mirror, post-merge-push, retro ride env). R2 reads
  "reached" on what is specced; coverage of the old member's clauses is not a rung.
- **Old-contract retirement depends on another island.** `⚑ gap` rows (LAUNCH-ADMIT-NO-MODEL,
  LAUNCH-BUDGET-CR, the `/route` retry) close only when the old proxy retires (FU-270: the gateway
  path is platform-only and opt-in).

## The island's own items

- Admission component in Python from `admission.md` — #3484.
- The launcher's admission: refusals before any request — #3486; the request, answers and exit
  mapping — #3408.
- One exit-code convention (exit 0 and exit 1 both mean defer) — LAUNCH-DISPATCH-EXIT ⚖; nothing filed.
- Spec pages for the unspecced clauses above — nothing filed.
- `gw_admit_lane` (specified, not implemented in the island helper) — nothing filed beyond #3484's scope.
- Line citations drifted from the spike base (`REPLAY:` sentinels are the anchor) — nothing filed.

## In flight

- R3/R6: Goal #3390 (open, `goal/post-launch`): children #3392, #3393, #3446, #3457 closed; bucket #3403 has 0 children.
- R4/R3/R6: Goal #3480 (open): #3483 worlds, #3484 Python component, #3485 ruled comparison, #3486 and #3408 launcher admission — all `agent/blocked`; goal branch uncut (intake comment on #3483; parking on #3437, open).
- R5: #3391 (`agent/blocked`) and PR #3627 (open, not draft, `REVIEW_REQUIRED`).

## Next steps, in order

1. R5 — land #3391 / PR #3627 so the suite runs in required CI. Waits on operator review (ci.yaml is operator-direct).
2. R4 — #3483 gateway-seam worlds. Waits on the operator cutting `goal/3480-launch-island-worlds-and-rows`.
3. R3 — #3484 rows from the page, in Python. Waits on #3483.
4. R6 — #3485 ruled comparison of `gateway-admit`; then #3486, #3408. Wait on #3484.
5. R4 — recorded GitHub worlds for the context bundle (LAUNCH-BUNDLE-*) with the scan recorder. Nothing filed.
6. R5 — evidence pack + spec gate/ratchets (borrow below). Nothing filed.
7. R7–R8 — only after a switch-over (`seat`). Nothing filed.

Real choice: 2 vs 5 first. The gateway seam is hand-written by design (#3483 validates against the
supplier schema); the GitHub worlds could be recorded today. Recommendation: keep #3480's order,
since admission is the first component and its worlds are the seam.

## What it can lend, what it should borrow

- **Lends:** `tests/conftest.py` `replay_row()` — runs one replay row from a throwaway overlay copy
  of `agents/replay/` with the old member's path holding the file under test (no write under
  `agents/`). `test_gate.py`'s stub control (a stub target must fail every row). The schema-
  validated consumer world pattern once #3483 lands.
- **Borrows:** the evidence pack `islands/retro/scripts/evidence.sh` (sources
  `gateway/scripts/lib/snippets.sh`); the scan recorder `islands/scan/scripts/record_world.py` and
  strict reader `islands/scan/src/scan_island/strict.py` for GitHub worlds; page-row reading
  `islands/scan/tests/page.py`; the gateway's `spec_gate.py` / ratchets once they take a root argument.

**R4 fit.** Launch's inputs are four kinds. (1) GitHub: issue, comments, PR, reviews, check runs,
the failing run's log tail, the goal tree — the scan recorder fits, though it is PR-shaped
(`<world> <pr>…`, repo fixed to homelab) and a run log is text, not JSON. (2) Gateway answers
(`POST /sessions`, outcome, release, env pull) — not GitHub; the scan recorder does not fit; #3483
hand-writes them against the supplier schema. (3) Kubernetes: the AgentStack claim, an existing
pod, the ConfigMap and pod it writes — does not fit. (4) The pod's `AGENT_RUN_STATS` log line — does
not fit. The first world Goal #3480 needs is kind (2).

## Three-group sort

| Item | Group | Reason |
|---|---|---|
| R1, R2, R3 | common | every island needs a boundary, pinned specs and rule-labelled rows |
| R4 GitHub worlds | common | every island reads GitHub; one recorder serves all |
| R4 gateway / Kubernetes worlds | platform-common | only loop components consume the gateway seam and claims |
| R5 required CI step | platform-common | homelab `ci.yaml`; oracle-fleet has its own CI |
| R5 spec gate, ratchets | common | the snippets process defines them for any root |
| R6 | platform-common | replay families exist only in homelab |
| R7, R8 | common | Prometheus and the feedback loop apply to every island |
| R9, R10 | common | island intake runs for platform and stack islands alike |
| Supplier-schema validation of consumer worlds | common | any consumer of a specced supplier |
| #3484, #3486, #3408, exit-code ruling, unspecced clauses | island-only | launch's own contract |

## Not verified

- Whether an island-intake sitting has run for `launch` on the cluster (no cluster query).
- R10: whether any launch wait or escape reached the bar in the wait ledger.
- The total number of replay fixture dirs that source `agent-session.sh` (only the README table's
  42 family patterns were checked: each matches at least one fixture dir).
- PR #3627's check state (the brief's call budget; files and review state read only).
