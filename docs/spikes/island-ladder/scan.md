# Scan — position on the island maturity ladder

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca`, 2026-11-22.

## What it is

The scan island will own the agent loop's deterministic half: the scan's decision and dispatch,
the GitHub grammar, the updater, the review reflex, the major handoff and the liveness signals
([islands/scan/README.md](../../../islands/scan/README.md)). It replaces `agents/coordinator-scan.sh`
and its siblings (`update-pr-branch.sh`, `review-reflex.sh`, `major-handoff.sh`, `coordinator-session.sh`, …).
Two members have been rebuilt in Python under `islands/scan/src/scan_island/`: the updater
(`updater.py`, `renovate.py`) and the major handoff (`major_handoff.py`). Nothing of
`coordinator-scan.sh` itself is rebuilt yet. Nothing live reads `islands/scan/`; switch-over is a
separate `seat` decision.

## Position

| Rung | State | Evidence | Open item |
|---|---|---|---|
| R1 Boundary | reached | README with "What this replaces", "Consumer contracts", read set and revert class; facts file [docs/intake/scan.md](../../../docs/intake/scan.md) | nothing filed (final location is operator-only) |
| R2 Specs | reached | 7 contract pages + sibling `*.schema.json`, 35 `### SCAN-` requirements (`grep -c '^### SCAN-'`: scan-decision 12, dispatch 4, github-grammar 4, updater 4, review-reflex 5, major-handoff 2, signals 4); RULES/CONVENTIONS pinned at v0.6.9 in [specs/README.md](../../../islands/scan/specs/README.md) | — |
| R3 Evidence | partial | `pytest --collect-only`: 327 cases, 45 carry `rule()` (`-m rule`): SCAN-UPDATER-* (28 page rows) and SCAN-HANDOFF-* (17). 6 of 35 requirements proven by rule-labelled cases read from the page tables (`tests/page.py`); 28 carry `🚧 WIP` with no tests; 1 is `⚑ gap` (SCAN-SIGNAL-REVERT). 13 inline `⚑ gap` lines across pages | #3448 (scan-decision + github-grammar rows), #3656 (checkpoint (b)) |
| R4 Worlds | partial | 2 recorded worlds, `specs/worlds/pr-board/` and `pr-handoff/`, each with `provenance.yaml` (repo, visibility, argv per read, recorder commit, REST description commit), hand-written write answers validated against extracted schemas; strict fake `gh` (`tests/fake_gh.py`); only the GitHub surface is recorded. The other 29 requirements still name replay worlds | #3657 (world `goal-checkpoint`), #3448 |
| R5 Gates | partial | Suite runs at a ride's `pr-open` via `scripts/diff-ci.sh` row `-- bash islands/scan/scripts/ci.sh`; in GitHub CI it runs only inside the "Scan specs site publish" step, which does not fail on a red suite (`.github/workflows/ci.yaml` comment). No spec gate, join ratchet or hygiene ratchet (gateway's `spec_gate.py`, `spec-join-ratchet.py`, `spec-hygiene-ratchet.py` read `gateway/` only). Specs reviewer reads rows with no evidence: claim `extraSpecs` root with no tests root (`agents/fixer/openrouter-operator/agentstack.yaml`) | #3391 / PR #3627 (open); ratchets and evidence-in-pack: nothing filed |
| R6 Replaces the old | partial | Families compared: 2 (`updater` 43 rows: 28 equal, 15 ruled `old` in `tests/comparison/updater.rulings`; `major-handoff` 15 rows, all equal, 0 rulings). Families that map to scan: README names 28 family patterns ("about 95" fixture dirs); a `source:` grep over `agents/replay/fixtures/*/fixture.yaml` finds 108 dirs sourcing a scan member (~100 families via `families.tsv`), before whole-script bridges such as `updater`. No live caller switched; nothing retired | #3389 (suite over replay families), #3660 (`goal` rows as ruled comparison) |
| R7 Metrics | absent | The island has no gauges or alerts; SCAN-SIGNAL-PHASE/-DISPATCH/-CLASS specify the old member's pushgateway series (all `🚧 WIP`). Facts file §Sources: "none of its own — nothing under `islands/scan/` is deployed". The specs site is a reader page, not a dashboard | nothing filed |
| R8 Feedback loop | absent | Facts file: "a body on this island carries `Experiment: none`"; nothing deploys, so no release verdict can exist | nothing filed (needs R6 switch-over first) |
| R9 Intake | partial | Selector row in `islands/intake/scripts/intake-select.sh` (`--island scan`); a sitting filed Goal #3656 and its children #3657–#3661. Facts file is stale in two places: "Evidence first: every requirement is `🚧 WIP — no evidence pipeline yet`" and "No tests root is declared and no evidence exists" (both untrue since a715541b). README §Open repeats "No evidence pipeline" | nothing filed |
| R10 Learns | absent | No scan-specific learning step. The shared wait/escape reads (`islands/intake/rules/intake-wait.md`, `intake-escape.md`, `scripts/intake-wait-ledger.py`) can propose rule-line edits for any island; whether any scan record reached the bar is not verified | nothing filed |

## Not on the draft ladder

- **World mining as a service to other islands.** Scan holds the only recorder, fake client and
  replay-lift in homelab's islands. No rung covers "lends its worlds machinery".
- **A ruled replay comparison** (`tests/compare.py` + `comparison/<family>.rulings`): lifts a replay
  row onto a recorded world and requires a `spec`/`old`/`new` ruling per difference. R6 says
  "compared and ruled" but not that the comparison is itself a tested harness.
- **A browsable specs site** (`mkdocs.yml`, `islands/scripts/specs-site.sh`,
  scan-specs.homelab.teststuff.net) joining suite results into the tables. Scan was first.
- **Sequence worlds** (successive wakes over one Goal) — the checkpoint pilot
  ([world-model-pilot.md](../../../islands/scan/world-model-pilot.md)) needs a world that spans
  time, which the two snapshot worlds do not.
- **One-model-several-views trial** (generate the decision table from one YAML model, gate render
  drift) — a spec-process experiment, not a rung.
- **Seams it does not own**: the footprint predicate (`agents/footprint.sh`) is read by five other
  components; the island consumes it and must not fork it.

## The island's own items

- Checkpoint (b) hold over recorded wakes and the one-YAML-model trial — Goal #3656 (children
  #3657–#3661; trial issue #3550).
- Checkpoint (b) marker surviving a deferred launch — #3553 (FU-199), unlabelled, waits on a ruling.
- SCAN-GH-ONE-BLOCK, the five facts in one machine block (ADR-122 (3)) — #3461, `blocked-on: human`
  (does lifecycle state live in the block or stay a label).
- The scan-decision and github-grammar rows as rule-labelled tests — #3448.
- The `fu124-nudge` half of SCAN-UPDATER-RENOVATE (the scan clause) — inside #3448's scope by page; no separate issue.
- Self-routing `⚑ gap`s (`coordinator_rail`, `rail_model`, reflex rail tick gate, `/router-status`,
  `/report/latest`) — gap rows on dispatch, review-reflex, scan-decision; nothing filed separately.
- Switch-over of each member and retirement of the old scripts — nothing filed (`seat` only).
- SCAN-SIGNAL-REVERT, the island's detector, revert path and drill — nothing filed.

## In flight

- R3/R4: Goal #3490 (open, `goal/post-launch`; assembly PR #3561 merged as a715541b) — owns the Status cells of the 6 tested requirements.
- R3/R4: Goal #3656 (open, `task/goal`; `goal/3656-scan-checkpoint-b` absent on origin per `git ls-remote`) — #3657, #3658, #3659, #3660, #3661 all `agent/blocked`.
- R3: #3448 (`agent/blocked`); its last comment says the wait on #3490 is satisfied and asks the next sitting to re-decide.
- R3/R6: Goal #3389 (open, `goal/post-launch`) — owns the `🚧 WIP → #3389` marks.
- R3: #3461 (`agent/blocked`, `blocked-on: human`); #3553 (no labels).
- R5: #3391 (`agent/blocked`) / PR #3627 (open) — required `ci` would run the island suites.
- R6: #3550 trial (`agent/blocked`), carried by #3656.

## Next steps, in order

1. **R5 — make the suite a required gate**: PR #3627 / #3391. Waits on the operator (`.github/**` is
   operator-direct). Do this first: today a change can red the 45 rule cases and still merge.
2. **R9 — correct the facts file and README §Open** to say a tests root and two recorded worlds
   exist. Nothing filed; a ≲5-minute bookkeeping fix; waits on nothing.
3. **R3/R4 — #3448**, the scan-decision and github-grammar rows over recorded worlds. Waits on an
   intake re-decision (its blocker is met). This is where most of the 29 unproven requirements sit.
4. **R3/R4/R6 — Goal #3656** (checkpoint (b), sequence world, `goal` replay rows ruled). Waits on
   operator Goal admission. Real choice with step 3: #3656 tests sequence worlds and one-model
   views that every island would borrow; #3448 covers more rows. Recommendation: #3448 first,
   because #3656's child #3660 rules `goal` rows that belong to the SCAN-CLAUSE-GOAL page #3448 re-sources.
5. **R3 — #3461** after its ruling (block vs label); then #3553 after its ruling.
6. **R5 — spec gate, join ratchet, hygiene ratchet and an evidence-carrying specs-review pack** over
   `islands/scan/specs`. Nothing filed; the gateway scripts exist but are scoped to `gateway/`.
7. **R6 — remaining families compared** under #3389, then a per-member switch-over (updater and
   major handoff are the candidates: both fully compared). Nothing filed for switch-over; `seat`.
8. **R7, R8, R10** only after a switch-over: before it the island emits nothing and ships nothing.

## What it can lend, what it should borrow

Lend (paths under `islands/scan/`):

- **Recorder** `scripts/record_world.py`: records `gh` reads byte for byte, refuses private repos,
  falls back to unauthenticated REST on 403, writes `provenance.yaml`, extracts write-response
  schemas from `github/rest-api-description` at a named commit. Scan-specific: `REPO` is hard-coded
  to `teststuffstash/homelab`, the read plans are a `PLANS` dict of two scan surfaces
  (`plan_pr_handoff`, `plan_pr_board`), and `WORLDS` resolves inside the island. Another island
  would add its own plan function and parameterise repo and root.
- **World rules** in `specs/worlds/README.md` §Recorded worlds (whole answers, value overrides only,
  strict on both sides, writes declared never performed) — island-neutral text.
- **Fake `gh`** `tests/fake_gh.py` + serving helper `tests/world.py` (overrides, faults, unrecorded
  call fails the case) — island-neutral except `WORLDS` path; GitHub surface only.
- **Strict reader** `src/scan_island/strict.py` and **write-answer validation** `tests/test_world_writes.py`.
- **Ruled comparison** `tests/compare.py` + `tests/replay.py` (replay adapter) +
  `comparison/*.rulings` — usable by any island with `agents/replay/` families; the lift assumes
  `gh`-served family worlds.
- **Page-as-parameters** `tests/page.py` and the `rule()` marker `tests/rules.py` (`SCAN-` heading
  regex is the only scan-specific line).
- **Specs site** opt-in shape (`mkdocs.yml` inheriting `gateway/mkdocs.yml`).

Borrow:

- Spec gate, join ratchet, hygiene ratchet: `gateway/scripts/spec_gate.py`, `spec-join-ratchet.py`,
  `spec-hygiene-ratchet.py`.
- Evidence publication: `gateway/scripts/gateway-evidence.sh` (scan has no publisher, so nothing
  is "verified" in rule 5's sense).
- World quarry / series census method from oracle-fleet `specs/worlds/README.md` (cited by the
  pilot; not read here).
- Kubernetes and Prometheus recordings: none exist in homelab islands; scan's dispatch, phantom
  and signal rows need them.

## Three-group sort

- R1, R2, R3, R4, R5: common — every island and the stack island need boundary, pinned specs, rule-labelled evidence, recorded worlds, gates.
- R6: platform-common — replay families and old members exist only in homelab's loop.
- R7: common — Prometheus metrics and alerts apply to any deployed island; scan has none until switch-over.
- R8: common — the feedback loop is the same mechanism for platform and stack.
- R9: common — island intake runs the same rules home for every island (`islands/intake/CONTRACT.md` for stacks).
- R10: common — the wait/escape ledger is intake-wide.
- Recorder, world rules, fake `gh`, strict reader: common (stack-common in practice: oracle-fleet has its own; reconcile, not duplicate).
- Ruled replay comparison: platform-common.
- Specs site: common (gateway, scan, oracle all have one shape).
- Sequence worlds / one-YAML-model trial: common (any state machine over time).
- Required-ci gate for island suites (#3391): platform-common (homelab `ci.yaml`).
- Facts-file correction, #3448, #3461, #3553, #3656, self-routing gaps, footprint seam, switch-over: island-only.

## Not verified

- Current pass count: I collected (327 cases, 45 `rule`), did not run the suite.
- Exact number of replay families that belong to scan: the `source:` grep misses whole-script
  bridges and catches shared-predicate users; 95–110 fixture dirs is the honest range.
- Whether any scan wait or escape record reached the intake ledger's bar (records live in the
  sitting's store, not in the tree).
- Whether #3656 was filed by an intake sitting or by hand (taken from the brief; the issue
  author was not read).
- oracle-fleet's world machinery (not read; no other repo sha recorded).
