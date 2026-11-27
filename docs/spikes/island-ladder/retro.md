# Retro — position on the island maturity ladder

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca`, 2026-11-22.

## What it is

The retro island will own the weekly retro series: guard, pipeline, activity, cells, harvest and
findings ([islands/retro/README.md](../../../islands/retro/README.md)). It replaces
`agents/retro_activity.py`, `retro_pipeline.py`, `retro_findings.py`, `retro_queue.py`,
`retro_guard_expr.py`, `retro-session.sh`, `retro-project.sh`, `retro-report-floor.sh` and their
manifests (`agents/coordinator/retro-argo.yaml`, `retro-activity-argo.yaml`). Two components are
rebuilt in Python under `islands/retro/src/retro_island/`: `guard_expr.py` (RETRO-GUARD-EXPR) and
`report_floor.py` (RETRO-REPORT-FLOOR). Nothing live reads `islands/retro/`; switch-over is a
separate `seat` decision.

## Position

| Rung | State | Evidence | Open item |
|---|---|---|---|
| R1 Boundary | reached | README with "What this replaces — still live", "Contracts" (consumes 7, exposes 5), read set, revert class; facts file [docs/intake/retro.md](../../../docs/intake/retro.md) | nothing filed (final location is operator-only) |
| R2 Specs | reached | 6 contract pages + 6 sibling `*.schema.json`, 28 `## RETRO-` requirements (`grep -c`: activity 4, pipeline 5, guard 4, cell 6, harvest 4, findings 5); RULES/CONVENTIONS pinned at v0.6.9 in [specs/README.md](../../../islands/retro/specs/README.md) | — |
| R3 Evidence | partial | `bash islands/retro/scripts/ci.sh` → rc 0, `26 passed` (not the 8 reported to the seat); 13 `rule()`-labelled: RETRO-GUARD-EXPR 5, RETRO-REPORT-FLOOR 8. Local evidence pack (`scripts/evidence.sh`, the pinned snippets wheel via `gateway/scripts/lib/snippets.sh`): per page "5 rows · 5 proven"; codes `CELL_MISMATCH 5`, `ROW_UNSPECIFIED 3`, `THREAD_BROKEN 10`, `STEP_FLAT 10`, `ROW_UNPROVEN 0`. Test rows are hand-copied into `pytest.param` (not read from the page). 2 of 28 requirements have cases; the page Status cells still say "no evidence pipeline yet"; nothing published | #3488 (rows from the page over a recorded world), #3384 (post-launch, open) |
| R4 Worlds | absent | `islands/retro/specs/worlds/` holds only `README.md`, which indexes replay fixture dirs and three in-process suites ("the bucket, the Prometheus and GitHub are stubs") | #3487 (definition, recorder, strict reader, world `prom-instant`) — `agent/blocked` |
| R5 Gates | partial | Suite runs at a ride's `pr-open` via `scripts/diff-ci.sh` row `-- bash islands/retro/scripts/ci.sh` ("pr-gate is the only place it runs today"). `grep -n "islands/retro" .github/workflows/ci.yaml` → no match; the `retro-test` step there runs the OLD members' tests. Evidence join codes are reported, never gated (`evidence.sh` header); no spec gate or ratchets; specs reviewer reads rows under `extraSpecs` (#3379) with no evidence | #3391 / PR #3627 (open, review required); ratchets: nothing filed |
| R6 Replaces the old | partial | Families compared: 2 of 10 retro families (the README's 9 + `retro-series-identity`) — `retro-quiet-guard` (only its 5 `expr-*` rows; the oracle row must be green AND `decide()` must match the old `agents/retro_guard_expr.py` verdict) and `retro-cell-report` (all 5 cases, differential vs `agents/retro-report-floor.sh`: same rc, reason, bytes). No ruled differences recorded (none surfaced). Not compared: `retro-gateway-cell`, `retro-key`, `retro-harvest`, `retro-harvest-push`, `retro-push-belt`, `retro-activity-window`, `retro-rank-snapshot-exclusion`, `retro-series-identity`, the `prepare-*` / `quiet-push-*` rows of `retro-quiet-guard`. No caller switched; nothing retired | #3488 (guard as a ruled comparison), #3489 (findings block) |
| R7 Metrics | absent (island) | No gauges or alerts of its own. The old member owns `RetroReportOverdue` + `argocd/resources/pushgateway/retro-report.promtool-{rules,test}` (both exist) and `retro_report_last_success_timestamp`; RETRO-BELT specifies them and the README says the new component keeps that detector at switch-over | nothing filed |
| R8 Feedback loop | absent | Facts file: "`Experiment: none`"; nothing deploys. (The OLD retro is itself a feedback producer: findings → issues via the acceptance act — a different thing from this rung) | nothing filed (needs R6 switch-over) |
| R9 Intake | partial | Selector row (`intake-select.sh` lines 329, 370, 407); the island-intake CronWorkflow walks every listed island (`agents/coordinator/island-intake-argo.yaml`, `island=all`). Intake comment on #3487 (2026-11-16) parks it `blocked-on: issue=3438`. Facts file stale: "No tests root is declared and no evidence exists" | nothing filed |
| R10 Learns | absent | No retro-island learning step; the shared wait/escape reads (`islands/intake/rules/intake-wait.md`, `intake-escape.md`) apply. Not verified whether any retro record reached the bar | nothing filed |

## Not on the draft ladder

- **The island is itself the platform's learning loop.** The old retro produces findings that feed
  every other island's R8/R10. The ladder treats "learns" as a rung each island climbs; retro is a
  supplier of that rung, and its switch-over affects every island's feedback.
- **Stack series.** The retro already runs a stack series (oracle's `feedback-triage`, Wednesdays,
  ADR-146) with a PromQL guard over a stack gauge. A platform island serving stack-common needs no rung.
- **Fixture families the README does not name.** `retro-series-identity/{loop,series}` sources
  `agents/retro-session.sh` but is missing from the README's fixture list; `retro-gh-token-env`,
  `retro-pg-env` and `argv-payload/retro-handoff` are listed as shared with launch.
- **Evidence join quality.** The pack reports `CELL_MISMATCH 5` and `THREAD_BROKEN 10`: the cases
  pass but their parameters do not match the page cells. "Proven" on R3 does not yet mean "joined".

## The island's own items

- Recorded worlds, recorder, strict reader, world `prom-instant` — #3487.
- RETRO-GUARD-EXPR from the page's rows over `prom-instant`, replay as ruled comparison — #3488.
- Findings-block component (RETRO-FINDINGS-BLOCK) over a `reports` world — #3489.
- `retro-rank.py` with no live caller (RETRO-RANK-LEGACY `⚑ gap`) — nothing filed.
- Bucket-A count computed nowhere (RETRO-KPI-BUCKET-A `⚑ gap`) — nothing filed.
- `retro_queue.py` scans every issue of the target repo per acceptance (README §Open) — nothing filed.
- The busy probe has no fixture (RETRO-GUARD-BUSY) — nothing filed.
- Fix the 5 cell mismatches the evidence join reports — nothing filed.

## In flight

- R3/R6: Goal #3384 (open, `goal/post-launch`): children #3385–#3388 closed; bucket #3431 has 0 children.
- R4/R3/R6: Goal #3482 (open): #3487, #3488, #3489 — all `agent/blocked`; goal branch uncut, named act on #3438 (open, `agent/blocked`).
- R5: #3391 (`agent/blocked`) and PR #3627 (open, not draft, `REVIEW_REQUIRED`).

## Next steps, in order

1. R5 — land #3391 / PR #3627. Waits on operator review (ci.yaml is operator-direct).
2. R4 — #3487 `prom-instant` world and recorder. Waits on the operator cutting `goal/3482-retro-island-recorded-worlds` (#3438).
3. R3/R6 — #3488 guard rows from the page, ruled comparison. Waits on #3487.
4. R3/R6 — #3489 findings block over `reports`. Waits on #3487's world definition.
5. R3 — fix the join codes (cells, threading) so "proven" means joined. Nothing filed.
6. R4 — GitHub worlds for RETRO-ACTIVITY-* / RETRO-FINDINGS-RECONCILE with the scan recorder. Nothing filed.
7. R7–R8 — only after a switch-over (`seat`). Nothing filed.

Order note: the #3483 intake comment quotes `docs/agents/meta-state.md`: when the goal-branch gate
lifts, "gateway first, then retro". Recommendation: retro's Goal before launch's, since retro has
Python components already and its first world (Prometheus) needs no supplier schema.

## What it can lend, what it should borrow

- **Lends:** `scripts/evidence.sh` (raw Allure → evidence pack per spec page, pinned wheel sourced
  from the gateway — no second copy); `tests/conftest.py` `family_rows()` / `oracle_green()` (the
  replay family run read-only as an oracle, row id → green); the differential pattern in
  `tests/test_report_floor.py` (new component and old member on the same input: rc, reason, bytes);
  `record.py` for Prometheus instant queries once #3487 lands — any island with a PromQL guard.
- **Borrows:** page-row reading `islands/scan/tests/page.py`; strict reader
  `islands/scan/src/scan_island/strict.py`; the scan recorder `islands/scan/scripts/record_world.py`
  for its GitHub reads; the gateway's spec gate and ratchets once they take a root argument.

**R4 fit.** Retro's inputs are mostly not GitHub answers. (1) Prometheus instant query (the guard)
— the scan recorder does not fit; #3487 writes a separate `record.py`. (2) S3 objects on Garage:
`_ledger.jsonl` and `_retro/*` state — does not fit. (3) Kubernetes: the busy probe (pods in the ride
namespace) and AgentStack claims for repo scope — does not fit. (4) Committed files: ride logs and
harvested reports (`reports` world in #3489) — not wire answers; no recorder needed beyond copying
a public file with provenance. (5) GitHub: the activity collector (issues, timelines, reviews, check
runs), the reconciler's live GETs, `gh pr list` in harvest — the scan recorder fits in kind, but it
is PR-shaped and fixed to one repo, while the collector walks every claimed repo. (6) Gateway
admission — reached through the launch island, so launch's gateway worlds would serve it.

## Three-group sort

| Item | Group | Reason |
|---|---|---|
| R1, R2, R3 | common | every island |
| R3 evidence pack (`evidence.sh`) | common | snippets process tool, root-agnostic |
| R4 GitHub worlds | common | every island reads GitHub |
| R4 Prometheus worlds | common | any island with a PromQL guard or alert (oracle-fleet too) |
| R4 S3 / Kubernetes worlds | platform-common | loop state and claims |
| R5 required CI step | platform-common | homelab `ci.yaml` |
| R5 spec gate, ratchets | common | snippets process |
| R6 | platform-common | replay families exist only in homelab |
| R7, R8, R9, R10 | common | every island |
| Stack series support | stack-common | serves a stack's own retro (ADR-146) |
| #3487–#3489, rank/bucket-A/queue/busy items, join fixes | island-only | retro's own contract |

## Not verified

- Whether an island-intake sitting has run for `retro` on the cluster (no cluster query).
- R10: whether any retro wait or escape reached the bar.
- Where the reported "8 passed" came from; the run at `f1be04ca` gave 26 (13 labelled).
- Whether every repo the collector walks is public (the scan recorder refuses private repos).
- PR #3627's check state.
