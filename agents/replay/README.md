# `agents/replay/` — the clause-replay harness

Recorded world in, expected actions out. The mechanism doc is
[`docs/agents/workflow.md` §Replay harness](../../docs/agents/workflow.md#replay-harness); this
file is the map of the directory.

```
run.sh                  the runner — `bash agents/replay/run.sh [-v] [fixture-dir ...]`
stubs/gh                PATH-shim gh:      serves world/gh/,      records mutations
stubs/kubectl           PATH-shim kubectl: serves world/kubectl/, records mutations (incl. stdin)
stubs/_common.sh        world lookup, action recording, the read/write split
fixtures/<name>/
  fixture.yaml          what to run and how to judge it
  world/<tool>/*.json   RECORDED API responses, keyed by the invocation they answer
  expected/actions.txt  the action stream this clause must emit
  *.sh                  bridge / observation-point parts named by `parts:`
```

Run everything (what CI runs):

```sh
devbox run -- bash agents/replay/run.sh
```

## The cleanup contract (2026-08-12) — from 74 hand-copied fixtures to tables over named worlds

The harness grew rule-free by design (grow, then refactor); this section is the refactor,
designed from a full inventory during the goal-#278 postmortem session. **The doctrine core is
NOT in scope** — extraction-never-transcription, reads-die/writes-succeed, action-stream-only
assertions, PROBE-FAIL self-tests, seams-not-backdoors all stand. The mess is packaging, and it
was measured before it was judged:

- 74 fixtures, ~20 families existing only as name prefixes; ownership recorded in THREE places
  (FSM `replay:` lists, this README's register prose, dir names) — the dup-keys drift class.
- **Zero worlds shared by reference** (bridges have `file:../`, 19 uses; worlds have no
  mechanism): 53 of 142 world files are byte-identical copies, and worse, **23 recurring world
  paths have DIVERGED copies** (`gh/issue-list.json`: 11 fixtures, 9 variants) — intentional
  row-delta and accidental drift are indistinguishable. Sharing already crosses family lines
  (c4c5-infeasible × harvest-goal both copied the circles#29 world) with no name for the shared
  thing. 48 bridge/post scripts are byte-identical; two expected streams are byte-identical.
- The platform's own testing doctrine (docs/agents/README.md rule 2: decision tables, never N
  near-duplicate tests) is violated by the harness that enforces it: a family IS a decision
  table, stored as N copied directories.
- No re-record path: worlds are recorded once by a hand-run `gh api … | tee`, provenance is
  prose, and an upstream API change keeps every fixture green while the live clause breaks.

**The seven moves, in dependency order** (execute 1–3 before the FU-168 fix round — its
deliverables all ride the clause-lane serialization this removes; migration of existing families
follows fix-density per ADR-103, never big-bang):

1. **Named world registry** — `agents/replay/worlds/<name>/`, the tree's ~dozen real source
   worlds (`circles-29-tree`, `homelab-alert-board`, …) as first-class named entities, each with
   machine provenance (`recorded: {cmd, at, source}`). Fixtures/rows reference a world and patch
   their delta onto it. Re-record becomes per-world and mechanical: `run.sh --rerecord <world>`
   replays the stored commands, and every dependent row re-validates in one pass. A `record`
   wrapper stamps provenance at capture time; `recorded` vs `constructed` becomes a field, not
   a sentence. **Maintenance half LIVE (same PR as move 2):** `--record <world> <rel> -- <cmd>`
   stores + stamps in one act; `--rerecord <world> [--write]` replays stamped commands and diffs
   — upstream drift stops being invisible. **v1 LIVE 2026-08-12 (PR after #382):** `world: <name>` in fixture.yaml +
   materialized overlay (base copied, fixture files win — stubs AND seam-reading bridges see one
   plain directory), first registry entry `worlds/circles-29-tree/` (6 fixtures dedup'd, 6 shared
   files, provenance.yaml with the reconstruction note). Remaining half: the `record` wrapper +
   `--rerecord`.
2. **Table mode** — `mode: table`: one fixture per family = family header (the contract prose,
   once) + `bridge.sh` + `rows.psv` (a pipe-delimited decision table: id · world · patch · env ·
   expect · params) + `expected/<verdict>.txt` templates parametrized by row. Base worlds are
   CLEAN; a row's jq-patch ADDS its condition and **must change the base** (a no-op patch is
   red). Rows report as `<family>/<row-id>` in CI. Overlay files (`patches/<row>/`) are the
   exception for whole-file non-JSON deltas, same must-differ rule. Pilot: `fix-debounce`
   (8 dirs → 1 family, 3 worlds, 2 templates; two of its inert rows share a byte-identical
   stream today and will share a template structurally). The witness pattern becomes
   structural: a constant like the SELFREF line lives once in the base world and every row
   inherits it. **PILOT LIVE 2026-08-12 (same PR as moves 1b/6):** `mode: table` in run.sh —
   rows synthesize ordinary actions fixtures at run time (the table is sugar over the proven
   machinery, not a second path); `fix-debounce` converted 8 dirs → 1 family (2 worlds, 2 shared
   templates + 3 per-row, 2 named jq patches, all 8 original streams reproduced exactly).
   Patches are named files (`patches/*.jq`) — raw jq in a cell collides with the psv delimiter
   and a named patch reads as the condition it encodes.
   **Batches 2–4 executed by [stint](../../docs/agents/chainless-redesign.md) #661
   (2026-08-19):** go-rail-latch 11→1,
   fu088-ladder + goal-budget-refusal 5+5→2, retro-harvest + summary-comment 5+4→2
   (PRs #673/#677/#681, every stream byte-exact); the #354 post-refactor adversarial
   acceptance PASSED first try (PR#684, record on #666).
3. **Generated register** — `run.sh --index --write` renders the family/world/row table from
   fixture metadata (the `merge-path-lint --write` pattern, currency-checked in CI). The
   hand-appended prose register below retires; this README keeps only doctrine — the ~8 seam
   patterns distilled from the 11 family essays. Kills the both-sides-append conflict class
   (PR#275).
4. **Metadata one-homes ownership** — `fixture.yaml` gains `family:`, `pins:` (FSM transition
   ids), `world:`, `requires:` (tools beyond bash/awk/jq). A bidirectional lint ties `pins:` ↔
   the FSM `replay:` lists; **the FSM stays the model home** — the lint checks agreement, it
   does not generate either side.
5. **Families become directories** — `fixtures/<family>/…`, shared bridges at family root (ends
   the 19 `../` reaches and the 48 script copies). One mechanical rename commit + FSM path
   updates. This is also FU-167 leg (b) — though its footprint half is now moot: **the
   companion option DECIDED 2026-08-18 (operator): `agents/replay/**` is EXEMPT from footprint
   semantics outright** (ADR-097 addendum — `fp_replay_exempt` in `agents/footprint.sh`,
   consumed by both the scan hold and the reviewer's `touches-check.sh`; the 41-PR
   zero-conflict measurement was the evidence). `Touches:` lines stop declaring this tree
   entirely; family dirs still land for dedup/ownership, not for declaration disjointness.
6. **Hermeticity contract** (homelab#329) — default: a fixture runs anywhere bash+awk+jq exist;
   anything more declares `requires:` and `run.sh` exits 2 naming the tool (the scan-wedge
   precedent promoted to rule). **Ambient env is part of the contract** (2026-08-18, three
   same-day sightings): `run.sh` unsets vars fixtures are known to default (`PROJECT`) at its
   top, so the pod's own env cannot leak into a fixture world — a bridge default `${VAR:-x}`
   is a leak vector; prefer hard values, and add newly-evidenced vars to run.sh's unset line,
   never per-bridge fixes. The 5 non-hermetic fixtures get lines or fixes.
   **Mechanism LIVE (same PR as move 2):** `requires:` in fixture.yaml, checked before dispatch,
   loud absence. The #329 set is declared (homelab#329): `scan-wedge-alert` declares `yq`+`promtool`,
   the `goal-ancestor` family is hermetic via the `$end`→`$stop` jq rename, and `scout-bench-*`
   pins a jq-version float format awaiting its emitter fix (the versions gap below).
7. **Suite fold-in** — the standalone `*-replay.sh`/`*-test.sh` harness scripts register as
   `mode: suite` entries (scripts stay put; `entrypoint:` points at them) so "executed replay"
   has one runner and one index. Bulk executed by stint #661 (PR#671, 5 standalone harnesses
   → `mode: suite`); stragglers roll by fix-density.

Until the moves land: new families SHOULD follow the target shape where cheap (name your world,
share it by reference within the family, keep contract prose in ONE header) — and every
deviation is one more directory the migration pays for later.

## Version-sensitive contracts the harness cannot pin (ratchet disposition, 2026-08-12)

The homelab#377 fix (`:-null` on every `jq -e 'type == …'` guard over a possibly-empty capture,
plus goal-budget.sh's bash-only runtime guard) ships with NO fixture change, deliberately: the
divergence it fixes exists only under the coordinator IMAGE's jq 1.6 (empty input exits 0,
inverting the guard), while this harness runs on devbox's pinned jq ≥ 1.7 — where the fixtures
pinning those guards (`goal-budget-refusal-unreadable`, `c4c5-infeasible-probe-fail`, …) already
executed the fail-closed branch and keep doing so, byte-identically, after the fix. A fixture
"for" the fix would assert nothing the suite doesn't already assert. The general gap — the
harness pins version-sensitive contracts on whichever toolchain serves it, so a green fixture
can invert in an image with older tools — is homelab#329's hermeticity territory (`requires:`
grew for tools; versions are the unbuilt half).

## Index (generated — move 3, live)

The derived register: every fixture, its mode/source, and the FSM transitions that pin it
(reverse-mapped from the three FSM yamls — the yamls stay the model home; this is a view).
Regenerate with `bash agents/replay/run.sh --index --write`; the full run REDS when this block
is stale, so it cannot drift the way the prose register did.

<!-- replay-index:begin — generated by `run.sh --index --write`; never hand-edit -->
| fixture | mode | world | source | pinned by (FSM) |
|---|---|---|---|---|
| `_selftest/missing-sentinel` | actions | - | `agents/coordinator-scan.sh` | - |
| `_selftest/unrecorded-read` | actions | - | `-` | - |
| `_selftest/wrong-expectation` | actions | - | `-` | - |
| `adopted-not-queued-surfaces/adopted-not-queued-surfaces` | actions | - | `agents/coordinator-scan.sh` | - |
| `arbitrate/blocked-on-human-bot-comment-after` | actions | - | `agents/coordinator-scan.sh` | - |
| `arbitrate/blocked-on-human-resolved` | actions | - | `agents/coordinator-scan.sh` | - |
| `arbitrate/blocked-on-human-review-only` | actions | - | `agents/coordinator-scan.sh` | - |
| `arbitrate/blocked-on-human-still-blocked` | actions | - | `agents/coordinator-scan.sh` | - |
| `arbitrate/first-tick` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `arbitrate/fu147-refire-blocked` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `arbitrate/goal-child` | actions | - | `agents/coordinator-scan.sh` | - |
| `arbitrate/landing-sequence` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `arbitrate/no-op-after-directive` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `arbitrate/probe-unreadable` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `arbitrate/quoted-mid-body` | actions | - | `agents/coordinator-scan.sh` | - |
| `argv-payload/over-ceiling` | actions | - | `agents/agent-session.sh` | - |
| `argv-payload/retro-handoff` | actions | - | `agents/retro-session.sh` | - |
| `argv-payload/warn-band` | actions | - | `agents/agent-session.sh` | - |
| `assembly-cr-debounced` | actions | - | `agents/coordinator-scan.sh` | - |
| `assembly-cr-dispatch-marker` | actions | - | `agents/coordinator-scan.sh` | - |
| `assembly-cr-emit` | actions | - | `agents/coordinator-scan.sh` | - |
| `assembly-cr-no-trailer` | actions | - | `agents/coordinator-scan.sh` | - |
| `assembly-cr-themed-emit` | actions | - | `agents/coordinator-scan.sh` | - |
| `asvs` | suite | - | `-` | - |
| `base-arm-master` | actions | - | `agents/agent-session.sh` | - |
| `base-arm-nonprotected` | actions | - | `agents/agent-session.sh` | - |
| `base-arm-research-goal` | actions | - | `agents/agent-session.sh` | - |
| `base-arm-research-master` | actions | - | `agents/agent-session.sh` | - |
| `board-classification/board-classification` | suite | - | `agents/board.sh` | - |
| `board-machine/board-machine` | suite | - | `agents/board.sh` | - |
| `body-block-malformed/body-block-malformed` | actions | - | `agents/coordinator-scan.sh` | - |
| `body-footprint-mismatch/body-footprint-mismatch` | actions | - | `agents/coordinator-scan.sh` | - |
| `c4c5-ambig-decidable-cross-repo` | actions | - | `agents/coordinator-scan.sh` | - |
| `c4c5-ambig-decidable` | table | - | `agents/coordinator-scan.sh` | IL-T29 |
| `c4c5-bodies-probe-fail/c4c5-bodies-probe-fail` | actions | circles-29-tree | `agents/coordinator-scan.sh` | - |
| `c4c5-infeasible` | table | - | `agents/coordinator-scan.sh` | IL-T06 IL-T26 |
| `changes-requested/blocked-held` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `changes-requested/blocked-on-human-still-blocked` | actions | - | `agents/coordinator-scan.sh` | - |
| `changes-requested/dispatched` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `changes-requested/reviewable-again-held` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `ci-failure-run-select/ci-failure-run-select` | actions | - | `agents/agent-session.sh` | MP-T12 |
| `ci-red-goal-head-excluded` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-sibling-mention` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-deferred-then-debounced` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-rerun-wake-dispatch` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-rerun-wake` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-rounds-two-channels` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `clause-replay-pairing/clause-replay-pairing` | table | - | `agents/coordinator-scan.sh` | - |
| `context-prefetch-nolabels` | actions | - | `agents/agent-session.sh` | - |
| `context-prefetch` | actions | - | `agents/agent-session.sh` | - |
| `context-prefetch/ci-red-unreadable` | actions | - | `agents/agent-session.sh` | - |
| `context-prefetch/ci-red` | actions | - | `agents/agent-session.sh` | - |
| `context-prefetch/fix-round-cm-refused` | actions | - | `agents/agent-session.sh` | - |
| `context-prefetch/fix-round-unreadable` | actions | - | `agents/agent-session.sh` | - |
| `context-prefetch/fix-round` | actions | - | `agents/agent-session.sh` | - |
| `coordinator-adopt-model` | table | - | `agents/coordinator-session.sh` | - |
| `decorrelate-resolution/empty-report` | actions | - | `agents/review-reflex.sh` | - |
| `decorrelate-resolution/malformed-json` | actions | - | `agents/review-reflex.sh` | - |
| `decorrelate-resolution/no-model` | actions | - | `agents/review-reflex.sh` | - |
| `decorrelate-resolution/served-model` | actions | - | `agents/review-reflex.sh` | - |
| `depends-on-retired-format/depends-on-retired-format` | actions | - | `agents/coordinator-scan.sh` | IL-T04 |
| `deploy-revert-token-clone/set` | actions | - | `agents/coordinator/deploy-revert-argo.yaml` | - |
| `deploy-revert-token-clone/unset` | actions | - | `agents/coordinator/deploy-revert-argo.yaml` | - |
| `dispatch-phase/scan` | actions | - | `agents/coordinator-scan.sh` | - |
| `dispatch-phase/session` | actions | - | `agents/coordinator-session.sh` | - |
| `done-phantom-belt` | actions | - | `agents/coordinator-scan.sh` | IL-T28 |
| `doorbell/collapse` | actions | - | `agents/coordinator-scan.sh` | - |
| `doorbell/fanout-wiring` | table | - | `agents/coordinator-scan.sh` | - |
| `doorbell/fanout` | actions | - | `agents/coordinator-scan.sh` | - |
| `doorbell/goal-fast-path` | actions | - | `agents/coordinator-scan.sh` | - |
| `doorbell/switchboard-capacity` | actions | - | `agents/coordinator-scan.sh` | - |
| `doorbell/switchboard-fanout` | actions | - | `agents/coordinator-scan.sh` | - |
| `doorbell/switchboard-routed` | actions | - | `agents/coordinator-scan.sh` | - |
| `doorbell/switchboard-unit` | actions | - | `agents/coordinator-scan.sh` | - |
| `env-card-docker-buildkit` | actions | - | `agents/agent-session.sh` | - |
| `env-card-ground-rules/empty` | actions | - | `agents/agent-session.sh` | - |
| `env-card-ground-rules/missing` | actions | - | `agents/agent-session.sh` | - |
| `env-card-ground-rules/unreadable` | actions | - | `agents/agent-session.sh` | - |
| `env-card-issue-context-gate` | actions | - | `agents/agent-session.sh` | - |
| `env-card-machine-markers/env-card-machine-markers-capture` | actions | - | `agents/agent-session.sh` | - |
| `env-card-mcp-present` | actions | - | `agents/agent-session.sh` | - |
| `env-card-mcp-present/opencode` | actions | - | `agents/agent-session.sh` | - |
| `epic-dispositions` | suite | - | `agents/epic_dispositions.py` | IL-T12 |
| `fix-debounce` | table | - | `agents/coordinator/fix-debounce-argo.yaml` | IL-T23 IL-T24 |
| `fleet-strike-reader` | actions | - | `agents/coordinator-scan.sh` | IL-T30 |
| `footprint-conflict-predicate/footprint-conflict-predicate` | suite | - | `-` | - |
| `footprint-hold-goal-exempt` | actions | - | `agents/coordinator-scan.sh` | - |
| `fu042-guard-a/fu042-guard-a` | actions | - | `agents/agent-session.sh` | - |
| `fu042-wip-cap` | actions | - | `agents/agent-session.sh` | - |
| `fu088-ladder` | table | - | `agents/agent-session.sh` | - |
| `fu124-nudge` | table | board | `agents/coordinator-scan.sh` | - |
| `fu143-fast-path-goal-head` | actions | - | `agents/coordinator-scan.sh` | - |
| `fu146-dispatch-loop-exit1` | actions | - | `agents/coordinator-scan.sh` | - |
| `fu146-dispatch-loop-scan` | actions | - | `agents/coordinator-scan.sh` | - |
| `go-rail-latch` | table | - | `agents/agent-session.sh` | - |
| `goal-ancestor` | table | - | `agents/agent-session.sh` | - |
| `goal-budget-gate` | table | - | `agents/agent-session.sh` | - |
| `goal-budget-refusal` | table | - | `agents/agent-session.sh` | - |
| `goal` | table | - | `agents/coordinator-scan.sh` | IL-T12 IL-T18 IL-T19 IL-T20 IL-T21 IL-T22 |
| `harness-enforce-default/explicit-wins` | actions | - | `agents/agent-session.sh` | - |
| `harness-enforce-default/flip` | actions | - | `agents/agent-session.sh` | - |
| `harness-enforce-default/monitor-untouched` | actions | - | `agents/agent-session.sh` | - |
| `harness-run-cmd/claude-mcp` | actions | - | `agents/agent-session.sh` | - |
| `harness-run-cmd/claude` | actions | - | `agents/agent-session.sh` | - |
| `harness-run-cmd/go` | actions | - | `agents/agent-session.sh` | - |
| `harness-run-cmd/goose-mcp` | actions | - | `agents/agent-session.sh` | - |
| `harness-run-cmd/goose` | actions | - | `agents/agent-session.sh` | - |
| `harness-run-cmd/opencode` | actions | - | `agents/agent-session.sh` | - |
| `harness-run-cmd/re-review-shadow-skip-tag` | actions | - | `agents/re-review.sh` | - |
| `harness-run-cmd/re-review-shadow` | actions | - | `agents/re-review.sh` | - |
| `harvest` | table | - | `agents/coordinator-scan.sh` | IL-T15 IL-T17 |
| `issue-body/issue-body` | suite | - | `-` | - |
| `issue-derivation` | suite | - | `-` | - |
| `item-class-batch/item-class-batch` | actions | - | `agents/coordinator-scan.sh` | - |
| `item-class/item-class` | actions | - | `agents/coordinator-scan.sh` | - |
| `ledger-emitter-rounds/ledger-emitter-rounds` | suite | - | `-` | - |
| `lens-posture/lens-posture` | suite | - | `-` | - |
| `loop-fetch-guard/loop-fetch-guard` | actions | - | `agents/coordinator-session.sh` | - |
| `merge-conflict/clause` | actions | - | `agents/coordinator-scan.sh` | MP-T06 |
| `merge-conflict/debounced` | actions | - | `agents/coordinator-scan.sh` | MP-T06 |
| `merge-conflict/null-author` | actions | - | `agents/coordinator-scan.sh` | MP-T06 |
| `merged-closeout-default-branch` | actions | - | `agents/coordinator-scan.sh` | IL-T09 |
| `merged-closeout-ilg06-detect` | actions | - | `agents/coordinator-scan.sh` | - |
| `model-id-carrier` | table | - | `agents/agent-session.sh` | - |
| `model-id-parse-drift/model-id-parse-drift` | suite | - | `-` | - |
| `opencode-hostaliases/default-profile` | actions | - | `agents/agent-session.sh` | - |
| `opencode-hostaliases/enforced-non-opencode` | actions | - | `agents/agent-session.sh` | - |
| `opencode-hostaliases/monitor-mode` | actions | - | `agents/agent-session.sh` | - |
| `opencode-hostaliases/node-profile` | actions | - | `agents/agent-session.sh` | - |
| `opencode-hostaliases/non-opencode` | actions | - | `agents/agent-session.sh` | - |
| `opencode-phonehome-killswitch/opencode-phonehome-killswitch` | suite | - | `-` | - |
| `opencode-session-config` | actions | - | `agents/agent-session.sh` | - |
| `opencode-session-config/with-mcp` | actions | - | `agents/agent-session.sh` | - |
| `pick-rail/both` | actions | - | `agents/subscription-latch.sh` | - |
| `pick-rail/clear` | actions | - | `agents/subscription-latch.sh` | - |
| `pick-rail/go` | actions | - | `agents/subscription-latch.sh` | - |
| `post-merge-push/detected` | actions | - | `agents/agent-session.sh` | - |
| `post-merge-push/silent` | actions | - | `agents/agent-session.sh` | - |
| `pr-cap-per-base` | actions | - | `agents/coordinator-scan.sh` | - |
| `pr-cap-per-base/collision` | actions | - | `agents/coordinator-scan.sh` | - |
| `pr-cap-per-base/counts` | actions | - | `agents/coordinator-scan.sh` | - |
| `pr-cap-per-base/jq-extraction` | actions | - | `agents/coordinator-scan.sh` | - |
| `preflight-malformed-block` | actions | - | `agents/agent-session.sh` | - |
| `queued-classification/held` | actions | - | `agents/coordinator-scan.sh` | - |
| `queued-classification/ready` | actions | - | `agents/coordinator-scan.sh` | - |
| `queued-derivation/no-agent-fix` | actions | - | `agents/coordinator-scan.sh` | - |
| `rail-degrade/rail-degrade` | suite | - | `-` | - |
| `reflex-tick/proceed` | actions | - | `agents/review-reflex.sh` | - |
| `reflex-tick/skip` | actions | - | `agents/review-reflex.sh` | - |
| `research-draw-roster/research-draw-roster` | actions | - | `agents/research-fanout.sh` | - |
| `resolve-model` | table | - | `agents/resolve-model.sh` | - |
| `responder-cause-line/absent` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-cause-line/already-bound` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-cause-line/cause-missing` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-cause-line/cause-unreadable` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-cause-line/issue-unreadable` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-cause-line/malformed` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-cause-line/valid` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-graduation/responder-graduation` | suite | - | `-` | - |
| `responder-remediation-would/responder-remediation-would` | suite | - | `-` | - |
| `responder-reopen/fix-verdict` | actions | - | `agents/coordinator/responder-argo.yaml` | IL-T03 |
| `responder-reopen/report-only` | actions | - | `agents/coordinator/responder-argo.yaml` | IL-T03 |
| `responder-selfref/platform-machinery` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-selfref/unlabelled` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-subject/homelab` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-subject/oracle-fleet` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-subject/witness-opted-infra-death` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-subject/witness-opted-negative-cost` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-subject/witness-unopted-phase-slow` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-subject/witness-unopted` | actions | - | `agents/coordinator/responder-argo.yaml` | - |
| `responder-touches-classify/responder-touches-classify` | suite | - | `-` | - |
| `retro-cell-report/longlog` | actions | - | `agents/coordinator/retro-argo.yaml` | - |
| `retro-cell-report/missing` | actions | - | `agents/coordinator/retro-argo.yaml` | - |
| `retro-cell-report/multi-block` | actions | - | `agents/coordinator/retro-argo.yaml` | - |
| `retro-cell-report/present` | actions | - | `agents/coordinator/retro-argo.yaml` | - |
| `retro-cell-report/skeleton` | actions | - | `agents/coordinator/retro-argo.yaml` | - |
| `retro-gh-token-env/set` | actions | - | `agents/agent-session.sh` | - |
| `retro-gh-token-env/unset` | actions | - | `agents/agent-session.sh` | - |
| `retro-harvest` | table | - | `agents/coordinator/retro-argo.yaml` | - |
| `retro-key/minted-block-style` | actions | - | `agents/retro-session.sh` | - |
| `retro-key/minted-labels-first` | actions | - | `agents/retro-session.sh` | - |
| `retro-key/minted` | actions | - | `agents/retro-session.sh` | - |
| `retro-key/pinned` | actions | - | `agents/retro-session.sh` | - |
| `retro-key/subscription` | actions | - | `agents/retro-session.sh` | - |
| `retro-push-belt` | table | - | `agents/coordinator/retro-argo.yaml` | - |
| `retro-rank-snapshot-exclusion/retro-rank-snapshot-exclusion` | suite | - | `-` | - |
| `review-flip-belt/probe-fail` | actions | - | `agents/coordinator-scan.sh` | MP-T14 |
| `review-flip-belt/review-flip-belt` | actions | - | `agents/coordinator-scan.sh` | MP-T14 |
| `review-phantom-belt` | actions | - | `agents/coordinator-scan.sh` | IL-T27 |
| `review-pick/behind-cr-no-content-held` | actions | - | `agents/review-reflex.sh` | MP-T03 |
| `review-pick/behind-first-review-admitted` | actions | - | `agents/review-reflex.sh` | MP-T03 |
| `review-pick/same-lane-oldest` | actions | - | `agents/review-reflex.sh` | MP-T03 |
| `review-pick/two-lanes-two-picks` | actions | - | `agents/review-reflex.sh` | MP-T03 |
| `reviewer-currency/behind-proceeds` | actions | - | `agents/reviewer-session.sh` | MP-T03 |
| `reviewer-currency/current-proceeds` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-currency/dirty-skips` | actions | - | `agents/reviewer-session.sh` | MP-T03 |
| `reviewer-currency/probe-fail-proceeds` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-depth-lane-split` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-exit-contract` | table | - | `agents/reviewer-session.sh` | MP-T03 |
| `reviewer-go-failover/available` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-go-failover/explicit-model` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-go-failover/limited` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-go-failover/shadow-both-limited` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-go-failover/shadow-go-available` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-mcp-prep/absent` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-mcp-prep/present` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-optout/reviewer-optout` | suite | - | `-` | - |
| `reviewer-route-carrier/rail-not-go` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-route-carrier/resolved-absent` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-route-carrier/resolved-adopted` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-touches/escapes-computed` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-touches/escapes-none` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-touches/multiline-union` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-touches/sentinel-exempt` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-touches/unavailable` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-touches/undeclared` | actions | - | `agents/reviewer-session.sh` | - |
| `route-request/labels` | actions | - | `agents/agent-session.sh` | - |
| `route-request/workbranch-tight` | actions | - | `agents/agent-session.sh` | - |
| `router-report-adhoc` | actions | - | `agents/agent-session.sh` | - |
| `router-report-no-ref` | actions | - | `agents/agent-session.sh` | - |
| `router-report-session-ref` | actions | - | `agents/agent-session.sh` | - |
| `router-report-strike-by-pod` | actions | - | `agents/agent-session.sh` | - |
| `run-phase-metric/run-phase-metric` | actions | - | `agents/agent-session.sh` | - |
| `scan-governance/non-dot-meta` | actions | - | `agents/coordinator-scan.sh` | - |
| `scan-governance/pre-dispatch` | actions | - | `agents/coordinator-scan.sh` | - |
| `scan-governance/set-unreadable` | actions | - | `agents/coordinator-scan.sh` | - |
| `scan-guarded/pre-dispatch` | actions | - | `agents/coordinator-scan.sh` | - |
| `scan-guarded/set-unreadable` | actions | - | `agents/coordinator-scan.sh` | - |
| `scan-lane-walk` | table | - | `agents/coordinator-scan.sh` | IL-T05 |
| `scan-phase-marker/scan-phase-marker` | actions | - | `agents/coordinator-scan.sh` | - |
| `scan-touches-footprint-hold/scan-touches-footprint-hold` | actions | - | `agents/touches-check.sh` | - |
| `scan-wedge-alert/scan-wedge-alert` | suite | - | `-` | - |
| `scout-bench/mcp-error` | actions | - | `agents/model-scout.sh` | - |
| `scout-bench/ranked-columns` | actions | - | `agents/model-scout.sh` | - |
| `scout-bench/unkeyed-unbenched` | actions | - | `agents/model-scout.sh` | - |
| `scout-canary-filing-gate` | table | - | `agents/model-scout.sh` | - |
| `scout-canary-mint-unbound` | actions | - | `agents/model-scout.sh` | - |
| `scout-canary-ride-model-prefix` | actions | - | `agents/model-scout.sh` | - |
| `scout-intake-stateless` | actions | - | `agents/model-scout.sh` | - |
| `scout-state-unkeyed` | actions | - | `agents/model-scout.sh` | - |
| `scout-variant/batch-rollout` | actions | - | `agents/model-scout.sh` | - |
| `scout-variant/known-base` | actions | - | `agents/model-scout.sh` | - |
| `session-atomic-gate/session-atomic-gate` | actions | - | `agents/coordinator-session.sh` | - |
| `session-belt/c4c5` | actions | - | `agents/coordinator-scan.sh` | - |
| `session-belt/fast-path-probe-fail` | actions | - | `agents/coordinator-scan.sh` | - |
| `session-belt/fast-path` | actions | - | `agents/coordinator-scan.sh` | - |
| `session-belt/queued` | actions | - | `agents/coordinator-scan.sh` | - |
| `slo-teeth/slo-teeth` | suite | - | `-` | - |
| `sprout-report-skips-buckets/sprout-report-skips-buckets` | actions | - | `agents/coordinator-scan.sh` | IL-T17 |
| `sprout-report-unbound` | table | normal | `agents/coordinator-scan.sh` | - |
| `state-fp/state-fp` | suite | - | `-` | MP-T11 |
| `strike-quota-classifier/strike-quota-classifier` | table | - | `agents/agent-session.sh` | - |
| `summary-comment` | table | - | `-` | - |
| `touches-check-predicate/touches-check-predicate` | suite | - | `-` | - |
| `touches-malformed/touches-malformed` | actions | - | `agents/coordinator-scan.sh` | - |
| `transcript-mirror-probe` | table | - | `agents/agent-session.sh` | - |
| `unblocked-unlabeled/blocker-open` | actions | - | `agents/coordinator-scan.sh` | IL-T01 |
| `unblocked-unlabeled/surfaces` | actions | - | `agents/coordinator-scan.sh` | IL-T01 |
| `unit-fast-path-author/unit-fast-path-author` | actions | - | `agents/coordinator-scan.sh` | - |
| `updater` | table | - | `-` | MP-T02 |
<!-- replay-index:end -->


## The seam patterns (distilled from the family essays — cleanup contract move 3)

The eleven per-family essays that used to live here were **collapsed to the patterns below**
(2026-09-05, the S5 heat pass — a 385-line never-targeted run below the index, homelab#1393).
Nothing is lost: the index above names every family and the FSM transitions it pins, each
fixture directory carries its own contract prose, and the essays are in git. What the README
keeps is DOCTRINE — the reusable seam shapes and the rule each one encodes.

- **S1 — Source the helper; redefine only its I/O seams.** `harvest-*` (ADR-102, homelab#207)
  sources `agents/goal-budget.sh` and shadows `gb_ledger` + `gb_cap`; `summary-comment-*`
  (ADR-103, homelab#210) sources `agents/machine-comment.sh` and shadows only `mc_now`;
  `goal-budget-refusal-*` (homelab#361) and `goal-ancestor-*` (homelab#367) source and redefine
  **nothing**, because the helper's own seams already reach the PATH-shim. Everything between the
  seams stays real arithmetic over the recorded world. Do it this way round: stubbing the whole
  helper pins the clause's *branching* and nothing else — and the reason the sum lives in a shared
  file is that a second copy would drift from the launcher's, so the fixture must be able to SEE
  that drift. Copying the helper into the fixture is worse (#166: a copy goes green while the
  original moves). Seams are ordinary shell functions declared in the helper's header; a clause
  that reaches for I/O with no seam gets one added THERE, never a `REPLAY_*` branch in production
  code — a test-only backdoor in a clause is a clause with an untested path.

- **S2 — Bound the MAGNITUDE through a seam, never the branching.** `argv-payload-*`
  (homelab#242) shrinks `ag_limit` (the kernel's 128KiB `MAX_ARG_STRLEN`) to 512 bytes rather
  than committing a 128KiB payload to assert arithmetic that does not change with scale. The real
  boundary is verified once against `execve()` (`env true` at 131071 OK / 131072 E2BIG, on the PR
  that added the guard) and the pair pins the two verdicts that flank it — a refusal that names
  the limit, and a warn band that does *not* stop the ride. Over-eagerness is the usual failure of
  a size check, so "89 % still dispatches" is pinned as behaviour, not trusted to prose.

- **S3 — Record the seam's read as a `CALL` line, and pin the clock loudly.**
  `fix-debounce-currency-*` (homelab#253) shadows `fc_am_alerts` (the Alertmanager GET, recorded
  into `world/alertmanager/alerts.json`) and `fc_now` (the clock the `endsAt > now` split turns
  on). A probe that silently stopped happening is a gate that silently stopped gating, and an
  unrecorded read leaves the stream identical either way — the responder's bridge writes
  `CALL curl …` for the same reason. `fc_now` reads `${FC_NOW:?…}` and dies naming the fixture's
  obligation, because a *defaulted* clock is a fixture asserting against an accident: every
  recorded `endsAt` would drift into the past and the family would converge on "resolved" while
  looking green. (`fixture.yaml`'s subset takes no inline comments — a trailing `# …` rides into
  the value and reaches `jq --argjson` as garbage.)

- **S4 — Shadow the TRANSPORT under the seam you are asserting.** `retro-key-*` (homelab#270)
  shadows `python3` itself so `estimate_budget.py`'s real pricing, tier choice and `emit_cr`
  rendering all stay under assertion and only the network leaves — prefer this to stubbing the
  mint, since the CR travels `kubectl apply -f -` and the thing worth pinning is the number in it.
  Fields with no fixed value (`expiresAt`) are `scrub:`bed to a shape rather than asserted, the
  treatment `summary-comment-*` gives its clock. `scout-bench-unkeyed-unbenched` shadows `curl` as
  a **tripwire** — record, then `exit 9` — so a gate that leaked reds instead of reaching the
  network from a cron pod.

- **S5 — A load-time script gets a `>>>REPLAY:*-seams>>>` block composed FIRST.** `scout-*`
  (FU-161, homelab#282/#469): `model-scout.sh` cannot be sourced the way a helper can — sourcing
  it *is* the weekly tick — so the seam definitions ship as their own extracted block, composed
  before the bridge, which then redefines exactly the I/O it must. Part order is the whole
  mechanism, and it is the reverse of the sourced-helper families: seams, bridge, clause.

- **S6 — Split a world's provenance and say which half is which; add a synthetic sibling when the
  real world conflates two rules.** `scout-variant-batch-rollout` carries digest #234's real ids
  with reconstructed price/`supported_parameters` rows around them; `scout-bench-mcp-error` pins a
  degrade for an upstream envelope this platform has never probed. A fabricated world is
  legitimate for pinning OUR side of a contract; it must not be presented as a recording of
  THEIRS. And because every suppressed id in #234's world was `:batch` AND had a known base, one
  rule could have been doing all the work — `scout-variant-known-base` separates them on a six-id
  catalog. (The scout family is also the first where the file changed AFTER the family existed:
  legs 3–4 edited the fixtures in the SAME commit as the digest, the ADR-103 move.)

- **S7 — Pin an emitter and its reader together or you have pinned neither.** `scan-phase-marker`
  + `scan-wedge-alert` (FU-145, homelab#283) are one pair split across the two modes: an `actions`
  fixture over the shipped `>>>REPLAY:scan-phase>>>` block (clock + `curl` shadowed, so the push
  URL and `in_deterministic` land in the stream), and a `suite` whose entrypoint lifts the alert
  expr OUT of the shipped PrometheusRule (annotations stripped — this pins firing, not prose) and
  replays series through `promtool test rules`, cross-checking both metric names against
  `coordinator-scan.sh` so a rename reds. An expr replayed against series nobody emits asserts a
  fiction; an emitter with no expr behind it is a metric nobody reads — the FU-145 defect was
  exactly a rule whose subject was not what its emitter measured. **A behaviour test earns its
  place by red-casing the bug it fixes**: the four replays were run against the pre-#283 expr and
  three go red.

- **S8 — A seam consumed through `$( )` is READ-ONLY; pin the clock per call, and assert the
  ACCUMULATION.** `run-phase-metric` (FU-160, homelab#287, reshaped by homelab#324): `run_phase`
  reads `rp_now` inside a command substitution and a subshell cannot write back, so a
  self-advancing clock would hand out its first tick forever and every phase would measure 0 with
  the fixture green — the bridge sets `RP_NOW` before each call and `rp_now` only reads it,
  `:?`-guarded. The pushgateway replaces per metric NAME within a group, so the growing STDIN
  block in `expected/actions.txt` is the real assertion: a fixture pinning only the URL goes green
  on an emitter that deletes every earlier phase. And **two runs that must be IDENTICAL are an
  assertion in their own right** — runs A and B differ only in whether the launcher survived the
  ride (what homelab#324 found the metric was silently encoding), and the claim is that their
  streams match byte for byte. When a contract is "X must not be observable", the shape that pins
  it is a pair of runs that differ in X, not a comment saying so.

- **S9 — Don't shadow a seam the harness already stubs.** `dispatch-phase-scan` +
  `dispatch-phase-session` (FU-160, homelab#319) are a pair split across two files because
  `agent_dispatch_phase_seconds` is emitted by two processes and a fixture takes one `source:`.
  The bridge leaves `dp_ring` ALONE so the Workflow read goes through the PATH-shim `kubectl` and
  the `creationTimestamp` → epoch conversion stays real arithmetic over a recorded payload;
  shadowing it would have pinned the branching and nothing about which object the clause reads.
  `STUB_KUBECTL=fail` then buys the degenerate leg for free (no RBAC, no Argo, a jail run) and
  pins that the ring ROW disappears while the scan row still ships. Two more rules: **two marks
  that red-case differently get different legs** (`scan` measures from the previous dispatch,
  `ring-to-scan` repeats unchanged at a second dispatch — only a third leg tells them apart), and
  **a payload the gateway would reject is not a green** (two samples with identical labels in one
  body is a rejected push, prometheus/pushgateway#232; the same run caught a single-shot family
  that was not newline-TERMINATED and would have 400'd on every real dispatch).

- **S10 — Hold the invocation constant and vary the WORLD; pin the SILENT arms.**
  `goal-budget-refusal-*` (homelab#361): all five bridges set the same six launcher variables and
  differ only in what the goal's timeline already carries — which is where the bug was (the dedup
  read only the LAST comment, so one interleaved `goal-review` re-admitted the refusal). A
  family that varied the CALL would have pinned five call sites and no world. The interesting
  streams are the four that add NO comment (edit-on-move, adoption of a pre-marker refusal, the
  no-op, and the fail-closed on an unreadable timeline via `STUB_GH=fail`) — pin only the
  first-touch create and every re-spam regression is free to come back. `goal-ancestor-*`
  (homelab#367) is the same shape pointed at a LOOKUP: the walk is pure shell over `gh`, so the
  hop SEQUENCE is the assertion — the shipped bug computed everything correctly about the WRONG
  issue, no output changed, only the reads moved. Its `post.sh` prints `GATE SUBJECT: #<n>`, the
  value the next clause consumes, which is how a resolution fixture asserts on enforcement it does
  not run; and `goal-ancestor-unlabelled-budget` exists purely to keep the walk's stop condition
  (a `task/goal` label, OR a `Budget:` line on a PARENTLESS issue — PR#1398 narrowed the line half) from decaying into an AND — a CONSTRUCTED world, and
  it says so, because a mis-authored goal is exactly what you cannot count on finding live.

## When the clause lives inside a manifest

- **S11 — A `# >>>REPLAY:<name>>>>` sentinel works inside a YAML block scalar.**
  `responder-reopen-*` (homelab#228) take their `source:` from
  `agents/coordinator/responder-argo.yaml`, whose `container.args[0]` carries ~300 lines of shell:
  `extract` trims leading whitespace before matching, so the sentinel sits at whatever column the
  manifest indents to and the block composes as ordinary shell. Two supporting rules live in the
  harness rather than the fixture: **`gh --jq` is evaluated by the stub, not ignored** (a stub
  serving the raw payload hands the verdict clause a JSON array where it expects an issue number;
  the body is served into a variable first, because `exit 9` from the left half of a pipeline is
  not an exit at all), and **the seam for non-`gh` I/O is a shell function in the bridge** writing
  `CALL curl …` into `$REPLAY_ACTIONS`, so "did this dispatch" is asserted in the same vocabulary
  as every label write — a third PATH-shim would work and buy nothing.

- **S12 — Read a DECLARATION out of the file; never transcribe it.**
  `retro-harvest-cell-errored` (homelab#268) is partly about a manifest FIELD: Argo, not any
  shell, decides that an OOMKilled cell is `Error` rather than `Failed`, and `continueOn` says
  whether the sibling and the harvest survive it — no clause reads that field and kubeconform
  SKIPs the CronWorkflow kind, so nothing was checking it. The bridge `awk`s the two cells'
  `continueOn` lines out of the shipped manifest as OUT lines, and the block replays what the
  harvest does with the world an errored cell leaves behind. Both halves are needed and neither is
  sufficient: the consequence replay passes on a manifest whose widening was reverted, and the
  declaration alone pins a string nobody has watched work. Reach for this ONLY when the field
  genuinely has no clause behind it — a value the shell branches on belongs in the action stream.

## Reads must be recorded; writes need not be

A READ with no world file DIES (loudly, exit 9) — an empty payload usually parses and the clause
then asserts on nothing. A WRITE with no world file SUCCEEDS silently: mutations are the output
under test, and most clauses never read the reply back.

That second half was documented from the start and did not work until homelab#208. `_rp_serve`'s
`exit 9` kills the whole stub process from inside a function, so the write path's `|| true` was
unreachable and every unrecorded mutation came back FAILED — clauses took their `gh write refused?`
branch and the fixture pinned the error path while looking like it pinned the happy one. Nothing
caught it because no fixture had yet written without reading back; the `goal-*` terminal fixtures
(`gh issue edit --add-label`, `gh issue close`) were the first. `_rp_serve <key> optional` now
returns 1 instead of dying, and the write path passes it.

Record a write anyway when the clause CONSUMES its output — `gh issue create` prints the new
issue's URL and `harvest-disposition` parses the number out of it.

`fixtures/_selftest-*` are PROBE-FAIL fixtures — deliberately broken, `expect: fail`, one per
detector the runner owns. They run first (the glob sorts them there) so the harness proves itself
before it judges anything else. If one of them ever goes green, the run fails loudly: a check
nobody has watched fail is not a check.

## When a clause file changes and no fixture can apply

The ratchet fails any PR touching a clause file without touching `agents/replay/` (EXEMPT since
2026-08-11: a pin-only diff to a pin-guarded clause file — the canonical no-fixture-applies case,
regexes sourced from `pin-only-lint.sh`), and names a note here as the alternative. Keep that hatch narrow by answering one question: **can the harness observe
this diff at all?** It asserts an action stream — the `gh`/`kubectl` calls a clause emits — so the
answer is no only when the diff emits none. "The branching is unchanged but the payload moved" is
observable, and there the ratchet is doing its job: extend the fixture.

Log each instance here, so the next author sees a register rather than a precedent. It is kept
**by CLASS** — the precedent is the class, the ids are the provenance (collapsed 2026-09-05, the
S5 heat pass; the per-instance prose is in git and in the cited PRs):

- **Class A — a DECLARATION to the scheduler/kubelet/controller.** No clause reads the field, no
  branch turns on it, and the diff emits no action stream. Evidence rather than assertion: the
  full suite stays green with every `expected/actions.txt` untouched. Instances: **homelab#103**
  (soft `topologySpreadConstraints` via `podSpecPatch` + Sensor CPU `requests` on
  `coordinate-argo.yaml`/`review-argo.yaml` — the entry that opens the class), **PR#548**
  (`statuses:write` added to the `reviewer-git` ESO `GithubAccessToken` generator; the
  sentinel's own posting is `scripts/iac-sentinel.sh`, script-side, not a clause file),
  **homelab#650 legs 1+2** (the `/sentinel` endpoint on the agent-loop EventSource — its
  siblings `/fix-verdict` and `/deploy-degraded` predate the ratchet's clause-file list for the
  same reason), **homelab#919** (`homelab.io/ephemeral` toleration inside an unquoted-heredoc
  pod manifest in `agents/agent-session.sh` — rendered inline, not a callable block),
  **homelab#867 / PR#952** (#103's block extended to the `agents/coordinator/*-argo.yaml`
  workflow specs plus a soft `nodeAffinity` de-preference for
  `node.longhorn.io/create-default-disk=true` nodes), **homelab#974 / PR#1000**
  (`limits.memory` 512Mi → 1Gi on the `coordinate` WorkflowTemplate's main container).
- **Class B — text OUTSIDE every `>>>REPLAY:` sentinel.** LLM-prompt prose, comments and
  redirections inside the `claude -p` invocations: the extracted clauses are byte-identical
  before and after, and prompt text emits no `gh`/`kubectl` calls. Instances: **homelab#536**
  (the TOOL_GAP marker instruction — `responder-argo.yaml` HARD RULES + `reviewer-session.sh`
  pod-side `PROMPT`), **homelab#556** (reviewer STEP-0: live-reviews-only precondition +
  machine-marker standing-aside dedup), **homelab#564** (the two HEREDOC-BACKTICK rewordings —
  backticks command-substitute even in `#` comment lines inside an unquoted heredoc, silently
  deleting the fragment from the delivered manifest; the lint's `scripts/fixtures/prompt-transport/`
  is its executable pin), **homelab#443** (dropping `2>/dev/null` from the four `--pick-rail`
  command substitutions — `$(…)` captures stdout alone, so every stream is byte-identical and
  the change only lets the latch's diagnostic stderr reach pod logs), **homelab#1035 / PR#1078**
  (two rationale comments restored inside `>>>REPLAY:config-defaults>>>` in
  `agents/coordinator-scan.sh`), **homelab#1403 / PR#1409** (reviewer STEP-0's anomaly arm: the update-branch re-point NOTE at `agents/reviewer-session.sh:511`, in the gap between the `lens-posture-handling` close at 493 and the `reviewer-touches-check` open at 571).
- **Class C — the retro lane's STANDING fixture debt** (observable diffs, no family to extend at
  the time). The **FU-058 belt** (2026-08-10, one appended `printf | curl` in `retro-argo.yaml`'s
  harvest step — the RetroReportOverdue success-timestamp push), three more jail-lane clause
  diffs on 2026-08-11 (`f791937` AWS_REGION in tsenv, `6b1ece6` harvest runs as root, `4db553e`
  bounded worst-K slice + pipefail), and the **guard stderr-fold fix** (homelab#237 — the
  busy-probe read kubectl's stderr "No resources found" as pod output via `2>&1` and refused
  every fire since unsuspend; fixed to a split-stream read, both legs verified live from the
  jail). **PARTLY PAID** by homelab#248 (`retro-cell-report-*` + `retro-harvest-*`, the first
  retro-lane family), extended by homelab#268 (`retro-harvest-cell-errored`, the DAG Error phase
  — §S12 above) and homelab#269 (`retro-harvest-slug-collision`: two cells on one model under
  different harnesses derive one slug, so the harvest disambiguates ON COLLISION ONLY, with
  `retro-harvest-slug` as the proof the ordinary names did not move). **Still unpaid, and still
  this entry's debt: the guard (busy-probe legs, ledger delta) and the harvest's git/gh half.**
  No FSM models the retro lane at all (dispatch-on-schedule machinery, roles.md; homelab#280
  ruled: correct the wording, do not model the lane yet), so there is no FSM-side
  `replay:`/`unreplayed` declaration to point at — the retro fixtures are helper-level pins
  under merge-path-lint's "no FSM transition references" visibility line. The next touch of
  either extends this family rather than opening a fourth register line.

Adding a fixture, recording a world, and the ADR-103 ratchet rule are all in the workflow doc.

## Pin-vacuity routing rule for coverage of unmodified behavior (ADR-103, 2026-09-05)

ADR-103's pin-vacuity gate (homelab#1107) rejects changed fixtures that pass against the
pre-fix tree. This is the right default — a fixture that passes on base adds no regression
coverage. But it has no opt-out, so in a clause-changing PR two requirements can be
simultaneously mandatory and unsatisfiable:

- the review rubric says *restore the regression coverage your PR dropped*, and
- the gate says *your changed fixtures must red on base*

— and a fixture pinning a branch the PR leaves **unmodified** necessarily passes on base.
That collision cost homelab#1151 a full round and homelab#1379 a round plus an arbitration.

### The two escapes

When a PR must add coverage for behavior it does **not** modify (e.g. restoring a fixture
dropped by a prior clause change, or adding coverage for an arm the PR leaves untouched),
use one of these routes:

**(b) Fold into a fixture that already reds on base** (preferred). If an existing fixture
whose world already exercises the arm you need fails on base for its own reasons, add your
assertion there and name why in the fixture header comment. The added assertion is not
vacuous (the fixture already reds), so the gate is satisfied honestly. No second PR, no
coverage loss.

- Worked example: homelab#1208 (PR #1208) put governance probe-fail cases inside
  `agents/replay/fixtures/scan-governance/set-unreadable/`, which fails on base for its own
  (operator-lane) reasons. The reasoning is written into that fixture's header comment.
- **Limitation**: (b) requires an existing fixture whose world already exercises the arm you
  need. The replay harness is one-world-one-arm (`fixture.yaml` → one world, one arm), so if
  the arm you need has no fixture whose world covers it, (b) does not apply.
- Counter-example: homelab#1379 (PR #1379) needed coverage for the **no-labels** arm of the
  context-prefetch clause. The `context-prefetch/` fixture's world carries labels, so the
  no-labels arm had nowhere to fold. The fixture was dropped from the clause-changing PR and
  re-landed via escape (a) as homelab#1384.

**(a) Fixture-only follow-up PR** (fallback). Pin-vacuity only runs when clause files ALSO
changed (`if [ -n "$clause" ] && [ -n "$replay" ]` in the CI workflow), so a fixture-only PR
is never vacuity-checked. Land the clause-changing PR without the fixture, then open a
second PR adding only the fixture.

- Costs a second PR and a second round, but is always available.
- Worked example: homelab#1384 (PR #1384), the fixture-only follow-up to homelab#1379.

### What this rule is not

Escape **(c)** — a `vacuity-exempt: <reason>` key in `fixture.yaml` that the gate honors — is
a deliberate ruling for the operator, not part of this deliverable. It lives in
`.github/workflows/ci.yaml` (an operator-lane path a worker cannot touch), and it is not
obviously needed if (b) is documented and (a) is available.

### Who this rule is for

The routing rule is as much for the **coordinator writing a directive** as for the worker and
the reviewer. The homelab#1379 collision was invisible to the coordinator that wrote the
round-3 directive — it ordered the unsatisfiable fixture in good faith, citing the ratchet's
*first* gate (which was already satisfied). The rule here prevents that class of directive.
