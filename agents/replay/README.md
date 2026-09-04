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
| `body-footprint-mismatch/body-footprint-mismatch` | actions | - | `agents/coordinator-scan.sh` | - |
| `c4c5-ambig-decidable-cross-repo` | actions | - | `agents/coordinator-scan.sh` | - |
| `c4c5-ambig-decidable` | table | - | `agents/coordinator-scan.sh` | IL-T29 |
| `c4c5-bodies-probe-fail/c4c5-bodies-probe-fail` | actions | circles-29-tree | `agents/coordinator-scan.sh` | - |
| `c4c5-infeasible` | table | - | `agents/coordinator-scan.sh` | IL-T06 IL-T26 |
| `changes-requested/blocked-held` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `changes-requested/dispatched` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `changes-requested/reviewable-again-held` | actions | - | `agents/coordinator-scan.sh` | MP-T11 |
| `ci-red-goal-head-excluded` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-sibling-mention` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-deferred-then-debounced` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-rerun-wake-dispatch` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-rerun-wake` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `ci-red-rounds-two-channels/ci-red-rounds-two-channels` | actions | - | `agents/coordinator-scan.sh` | MP-T12 |
| `clause-replay-pairing/clause-replay-pairing` | table | - | `agents/coordinator-scan.sh` | - |
| `context-prefetch` | actions | - | `agents/agent-session.sh` | - |
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
| `env-card-ground-rules/empty` | actions | - | `agents/agent-session.sh` | - |
| `env-card-ground-rules/missing` | actions | - | `agents/agent-session.sh` | - |
| `env-card-ground-rules/unreadable` | actions | - | `agents/agent-session.sh` | - |
| `env-card-issue-context-gate` | actions | - | `agents/agent-session.sh` | - |
| `env-card-machine-markers/env-card-machine-markers-capture` | actions | - | `agents/agent-session.sh` | - |
| `env-card-mcp-present` | actions | - | `agents/agent-session.sh` | - |
| `env-card-mcp-present/opencode` | actions | - | `agents/agent-session.sh` | - |
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
| `queued-classification/held` | actions | - | `agents/coordinator-scan.sh` | - |
| `queued-classification/ready` | actions | - | `agents/coordinator-scan.sh` | - |
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
| `reviewer-currency/behind-skips` | actions | - | `agents/reviewer-session.sh` | - |
| `reviewer-currency/current-proceeds` | actions | - | `agents/reviewer-session.sh` | - |
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


## When a clause depends on a sourced helper

`fixtures/harvest-*` (ADR-102, homelab#207) are the worked example: the clause under replay calls
`goal_budget_read` out of `agents/goal-budget.sh`. The bridge **sources that file from the
checkout** (`. "$REPLAY_ROOT/agents/goal-budget.sh"`) and redefines only its two I/O seams —
`gb_ledger` (the pushgateway scrape) and `gb_cap` (the estimator, which prices against a live
registry). Everything between them is real arithmetic over the recorded world.

`fixtures/summary-comment-*` (ADR-103, homelab#210) are the second pair, and the simplest shape the
harness supports: the bridge is the ONLY part. It sources `agents/machine-comment.sh` and redefines
one seam — `mc_now`, the wall clock, which would otherwise make the fixture red once per second.
The `gh` calls stay real and go through the PATH-shim, which is exactly what puts the find-or-create
decision (POST a new comment vs PATCH the existing one) into the asserted action stream.

Do it this way round, not the other. Stubbing the whole helper would pin the clause's *branching*
and nothing else, and the reason that sum lives in a shared file at all is that a second copy of it
would drift from the launcher's — so the fixture must be able to see that drift. Copying the helper
into the fixture directory is worse still, for the reason `run.sh` already gives about transcribed
clauses (#166): a copy goes green while the original moves.

The seams are ordinary shell functions, declared as seams in the helper's header. If a clause you
are pinning reaches for I/O with no seam, add one there rather than a `REPLAY_*` branch in
production code — a test-only backdoor in a clause is a clause with an untested path.

`fixtures/argv-payload-*` (homelab#242) are the third family, and the first whose seam is not I/O
at all: `ag_limit` in `agents/argv-guard.sh` returns the kernel's 128KiB `MAX_ARG_STRLEN`, and the
fixtures shrink it to 512 bytes. Same rule, different reason — a fixture that asserted the real
ceiling would have to commit a 128KiB payload to assert arithmetic that does not change with
scale. Bound the *magnitude* through a seam, never the branching. The boundary itself is not left
to the fixture's word: the guard refuses at exactly the size `execve()` does (verified against
`env true` at 131071 → OK / 131072 → E2BIG on the PR that added it), and the pair pins the two
verdicts that flank it — a refusal that names the limit, and a warn band that does *not* stop the
ride. Over-eagerness is the usual failure of a size check, so "89% still dispatches" is pinned as
behaviour rather than trusted to prose.

`fixtures/fix-debounce-currency-*` (homelab#253) are the fourth family, and the first whose seam
serves a world of its own: the queue-time currency gate reads live alert state, so the bridge
shadows `fc_am_alerts` (the Alertmanager `/api/v2/alerts` GET) and `fc_now` (the clock the
`endsAt > now` split turns on), and the recording lands in `world/alertmanager/alerts.json` —
beside `world/gh/`, but served by the seam rather than by a PATH-shim stub, and keyed by nothing
because a fixture pins one moment of the alert store. Two rules make it worth copying:

- **Record the seam's read as a `CALL` line.** A probe that silently stopped happening is a gate
  that silently stopped gating, and an unrecorded read leaves the stream identical either way. It
  is the same reason the responder's bridge writes `CALL curl …`.
- **Pin the clock through `env:`, loudly.** `fc_now` reads `${FC_NOW:?…}` and dies with a message
  naming the fixture's obligation, because a *defaulted* clock is a fixture asserting against an
  accident: every recorded `endsAt` would silently drift into the past and the whole family would
  converge on "resolved" while looking green. (`fixture.yaml`'s subset has no inline comments —
  a trailing `# …` on the list item rides into the value and reaches `jq --argjson` as garbage.)

`fixtures/retro-key-*` (homelab#270) shadow **`python3` itself** in the bridge — the seam pattern
the responder pair uses for `curl`, applied to a helper the clause SHELLS OUT to rather than
sources. `retro-session.sh` mints its cell's budget key by running `estimate_budget.py --emit-cr`,
which prices against the live OpenRouter registry; the shadow appends `--price-per-mtok` and calls
`command python3`, so the real estimator, the real tier choice and the real `emit_cr` rendering all
stay under assertion and only the network leaves. Prefer this to stubbing the mint: the CR travels
`kubectl apply -f -`, so its `budgetUSD` lands in the action stream as STDIN, and the thing most
worth pinning about that clause is the number in it. The one field with no fixed value —
`expiresAt`, now+4h — is `scrub:`bed to a shape rather than asserted, the same treatment
`summary-comment-*` gives its clock.

`fixtures/scout-*` (FU-161 legs 1–4, homelab#282/#469) are the sixth family and the first whose
subject is a top-level SCRIPT that runs its work at load time. `model-scout.sh` cannot be sourced the
way `goal-budget.sh` is — sourcing it *is* the weekly tick — so the seams reach the fixture the other
way the harness already supports: a `# >>>REPLAY:scout-seams>>>` block holding nothing but the
function definitions, composed FIRST, with the bridge composed after it and redefining exactly the
I/O it must. Part order is the whole mechanism, and it is the reverse of the sourced-helper
families: seams, then bridge, then the clause blocks. Three things worth copying:

- **Compose the seam you are asserting; shadow only the transport underneath it.** The keyless leg
  (`scout-bench-unkeyed-unbenched`) runs the REAL `scout_get_model` and lets its env gate decide,
  because "no key ⇒ every candidate `unbenched` ⇒ the tick still posts a digest" is the production
  path on merge day, not an edge case. Its bridge shadows `curl` as a **tripwire** — record, then
  `exit 9` — so a gate that leaked reds instead of reaching mcp.openrouter.ai from a cron pod. The
  benched leg shadows the same `curl` as a recording, and the JSON-RPC frames land in the action
  stream, which is the only place "one `get-model` per surviving candidate" is checkable at all.
- **Split the world's provenance and say which half is which.** `scout-variant-batch-rollout` is
  the acceptance case, and its 22 ids are digest #234's real ones; the price and
  `supported_parameters` fields around them are reconstructed, because the digest recorded ids
  rather than catalog rows. `scout-bench-mcp-error` goes further — it pins the degrade for an
  upstream envelope this platform has never probed. A fabricated world is legitimate for pinning
  OUR side of a contract; it must not be presented as a recording of THEIRS.
- **A synthetic sibling earns its place when the real world conflates two rules.** In #234's world
  every suppressed id was `:batch` AND had a known base, so one rule could have been doing all the
  work with the fixture none the wiser. `scout-variant-known-base` separates them on a six-id
  catalog — including a `:batch` id whose base is NEW (still dropped: exclusion is outright) and
  two within-tick variants of one new base (collapsed to the cheaper listing).

The scout family is the first where the file changed **after** the fixture family already existed —
legs 3–4 (homelab#469) landed on top of the leg 1–2 fixtures, so the fixture edits here are exactly
the ADR-103 move: `model-scout.sh` is in the ratchet's clause-file regex since #297, and the
`scout-bench-*` replays were updated in the SAME commit that changed the digest, not a follow-up.
`scout-canary-filing-gate` (mode `table`) is the family's decision-table entry — its four rows pin
the canary rail-probe verdicts, the contradiction retry rule, the filing-gate skip, and the
unparsable-stats→`unknown` fallback in one world.

`fixtures/scan-phase-marker` + `fixtures/scan-wedge-alert` (FU-145, homelab#283) are the seventh
family and the first **pair split across the two modes**, because the thing under test spans a
shell emitter and a PromQL expr. `scan-phase-marker` is ordinary `actions`: the shipped
`>>>REPLAY:scan-phase>>>` block, with `sp_now` and `curl` shadowed in the bridge, so the push URL
(namespace-keyed group, pod as a metric label) and the `in_deterministic` value land in the action
stream. `scan-wedge-alert` is `suite`: its entrypoint lifts the alert's expr OUT of
`argocd/resources/pushgateway/prometheusrule.yaml` (annotations stripped — this pins firing, not
prose) and replays series through `promtool test rules`. Two rules worth copying:

- **Pin an emitter and its reader together or you have pinned neither.** An expr replayed against
  series nobody emits asserts a fiction, and an emitter with no expr behind it is a metric nobody
  reads — the FU-145 defect was exactly a rule whose subject was not what its emitter measured. The
  suite also cross-checks the two metric names against `coordinator-scan.sh`, so a rename on one
  side goes red instead of going silent.
- **A behaviour test earns its place by red-casing the bug it fixes.** The four replays were run
  against the pre-#283 pod-lifetime expr before landing: three go red, including the healthy-18m
  ride the old rule fired on twice. `promtool` and `yq` come from devbox, so the suite exits 2
  naming the missing tool rather than skipping when run outside it.

`fixtures/run-phase-metric` (FU-160, homelab#287; reshaped by homelab#324) is the eighth family and
the launcher-side twin of `scan-phase-marker` — the same emitter shape (a
`>>>REPLAY:run-phase-metric>>>` block, clock and transport shadowed in the bridge), pinning
`agent_run_phase_seconds{phase=…}`. Three differences are the reason it is worth reading rather
than copied from its twin:

- **The clock is pinned PER CALL, not advanced by the seam.** `run_phase` reads `rp_now` inside a
  command substitution, and a subshell cannot write back — a self-advancing clock would hand out
  its first tick forever and every phase would measure 0 with the fixture green. So the bridge sets
  `RP_NOW` before each call and `rp_now` only reads it, `:?`-guarded. Any seam a clause consumes
  through `$( )` has this property; reach for the fix-debounce family's loud-clock rule, not for
  state inside the seam.
- **The assertion is the ACCUMULATION, not one push.** The pushgateway replaces per metric NAME
  within a group, so an emitter that pushed only the phase that just closed would delete every
  earlier one and each ride would end holding a single number. The growing STDIN block in
  `expected/actions.txt` is that rule under assertion — a fixture pinning only the URL would go
  green on exactly that bug, and it would surface as a dashboard that had quietly only ever shown
  `pod-spinup`.
- **Two runs that must be IDENTICAL are an assertion in their own right.** Runs A and B differ only
  in whether the launcher process survived the ride — the thing homelab#324 found the metric was
  silently encoding — and the fixture's claim is that their action streams match byte for byte.
  When a clause's contract is "X must not be observable", the shape that pins it is a pair of runs
  that differ in X, not a comment saying so; the calls the surviving run makes past the divergence
  point (`run_phase ride`, `run_phase bookkeeping`) are then the regression guard, and they assert
  by being REJECTED.

`fixtures/dispatch-phase-scan` + `fixtures/dispatch-phase-session` (FU-160, homelab#319) are the
ninth family and the second **pair split across two files**: `agent_dispatch_phase_seconds` is
emitted by two processes — the scan (`ring-to-scan`, `scan`) and the launcher it invokes
(`coordinator-spinup`, `coordinator-session`) — and a fixture takes one `source:`, so the two
halves are two fixtures that must be read together. Three things worth copying:

- **Don't shadow a seam the harness already has a stub for.** The ring edge is read off the scan's
  own Argo Workflow object, and the bridge leaves `dp_ring` ALONE: the call goes through the
  PATH-shim `kubectl`, so `get workflow <pod> -o json` lands in the action stream and the
  `creationTimestamp` → epoch conversion stays real arithmetic over a recorded payload. Shadowing
  it would have pinned the branching and nothing about which object the clause actually reads.
  `STUB_KUBECTL=fail` then buys the degenerate leg for free — no RBAC, no Argo, a jail run — and
  the fixture pins that the ring ROW disappears while the scan row still ships, and that the failed
  probe is retried at the next dispatch rather than latched off.
- **Two marks red-case differently, so give them different legs.** `scan` measures from the
  previous dispatch; `ring-to-scan` measures to the pod's start and therefore repeats unchanged at
  a second dispatch. Only the third leg (a second dispatch, a different stack) can tell those apart
  — collapse the two marks into one and every other leg stays green.
- **A payload the gateway would reject is not a green.** The session bridge resets its accumulator
  before the two refusal legs so each family carries every phase exactly once: two samples with
  identical labels in one body is a rejected push (prometheus/pushgateway#232), and the first draft
  of this fixture asserted one. The same run caught the shipped bug worth having a fixture for at
  all — a single-shot family that was not newline-TERMINATED, i.e. a body that would have 400'd on
  every real dispatch while every unit-level reading of the code said it was fine.

`fixtures/goal-budget-refusal-*` (homelab#361) are the tenth family and the plainest shape the
sourced-helper rule takes: the bridge sources `agents/machine-comment.sh` and redefines **nothing**.
The block under replay is `agent-session.sh`'s budget pre-flight refusal, which reaches GitHub only
through that helper's three I/O seams, and those go to the PATH-shim `gh` — so find-or-create lands
in the action stream for free and no seam needs shadowing. Two things worth copying:

- **Hold the invocation constant and vary the WORLD.** All five bridges set the same six launcher
  variables; what differs is what the goal's timeline already carries. That is where the bug was
  (the dedup read only the LAST comment, so one interleaved `goal-review` re-admitted the refusal),
  and a family that varied the call instead would have pinned five call sites and no world.
- **A level-triggered clause needs its SILENT arms pinned, not just its loud one.** The interesting
  streams here are the four that add no comment: the edit when the numbers move, the adoption of a
  pre-marker refusal left by the old code, the no-op when nothing moved, and the fail-closed when
  the timeline is unreadable (`STUB_GH=fail`, hence no `world/` in that directory). Pin only the
  first-touch create and every re-spam regression is free to come back.

`fixtures/goal-ancestor-*` (homelab#367) are the eleventh family and the first whose subject is a
LOOKUP rather than a computation: which of a ride's ancestors is the goal, walked by
`goal_resolve_ancestor` (`agents/goal-budget.sh`) and consumed by both the budget pre-flight and
the goal card. The bridge sources that helper and redefines **nothing** — the walk is pure shell
over `gh`, so every hop goes through the PATH-shim and the hop SEQUENCE is the assertion. Three
things worth copying:

- **When the defect is which rows you read, the CALL stream is the whole test.** The shipped code
  computed everything correctly about the wrong issue: one `/parent` hop landed on the ADR-102
  post-launch bucket, which has no `Budget:` line, so the gate read `no-budget` and waved the ride
  through while the goal was `exhausted`. No output changed; nothing was miscalculated. Only the
  reads moved, and only a fixture over the reads can see that.
- **Print the variable the NEXT clause consumes.** `post.sh` emits `GATE SUBJECT: #<n>` — the
  argument the pre-flight is about to pass to `goal_budget_read`. The observation-point trick that
  `goal-budget-refusal-first-touch` uses for "execution continued", pointed at a value instead of
  at control flow; it is what lets a resolution fixture assert on enforcement it does not run.
- **Pin every arm of a stop condition, including the one no live tree exercises.** The walk stops on
  a `task/goal` label OR a `Budget:` line, and three of the four fixtures stop on the label — so
  `goal-ancestor-unlabelled-budget` exists purely to keep the OR from decaying into an AND. Its
  world is CONSTRUCTED and says so: a mis-authored goal is exactly the shape you cannot count on
  finding live, which is why the untested half was the funded one.

## When the clause lives inside a manifest

`fixtures/responder-reopen-*` (homelab#228) are the first pair whose `source:` is not a `.sh` file
at all — it is `agents/coordinator/responder-argo.yaml`, whose `container.args[0]` carries ~300
lines of shell. Nothing special was needed: `extract` trims leading whitespace before matching, so
a `# >>>REPLAY:<name>>>>` sentinel sits happily inside the YAML block scalar at whatever column the
manifest indents to, and the extracted block composes as ordinary shell.

Two things that pair does need, and both live in the harness rather than the fixture:

- **`gh --jq` is evaluated by the stub, not ignored.** `coordinator-scan.sh`'s standing rule is to
  pipe to a real `jq`, so no fixture had exercised it; the responder's embedded script uses
  `gh api … --jq` directly, and a stub that served the raw payload would have handed the verdict
  clause an entire JSON array where it expected an issue number. An unrecorded read still dies
  loudly through it — the body is served into a variable first, because `exit 9` from the left half
  of a pipeline is not an exit at all.
- **The seam for non-`gh` I/O is a shell function in the bridge.** The verdict half rings a doorbell
  with `curl`; the bridge shadows `curl` and writes a `CALL curl …` line into `$REPLAY_ACTIONS`, so
  "did this dispatch" is asserted in the same vocabulary as every label write. Adding a third
  PATH-shim would have worked too and buys nothing — the function is the seam pattern the section
  above already describes.

`fixtures/retro-harvest-cell-errored` (homelab#268) is the first fixture whose subject is partly a
**declaration** rather than a clause. Argo — not any shell — decides that an OOMKilled cell is
`Error` and not `Failed`, and `continueOn` is the DAG field that says whether the sibling and the
harvest survive it; no clause reads that field, and kubeconform SKIPs the CronWorkflow kind, so
nothing was checking it. The bridge therefore `awk`s the two cell tasks' `continueOn` lines out of
the shipped manifest and prints them as OUT lines, and the block replays what the harvest does with
the world an errored cell leaves behind (no ride log at all — `tee` never ran, so the output
artifact is unresolvable and `optional: true` stages nothing). Both halves are needed and neither is
sufficient: the consequence replay passes on a manifest whose widening was reverted, and the
declaration alone would pin a string nobody has watched work. The rule this generalizes: read the
declaration OUT of the file (never transcribe it), and only reach for this when the field genuinely
has no clause behind it — a value the shell branches on belongs in the action stream instead.

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

Log each instance here, so the next author sees a register rather than a precedent:

- **homelab#103** — a soft `topologySpreadConstraints` (via `podSpecPatch`) and Sensor CPU
  `requests` added to `coordinate-argo.yaml` / `review-argo.yaml`. Pod *placement*, declared to the
  kube-scheduler: no clause reads it and no branch turns on it. Evidence rather than assertion —
  the full suite stayed green on the change with every `expected/actions.txt` untouched, which is
  the harness itself reporting that the streams did not move.
- **FU-058 belt (2026-08-10)** — one appended `printf | curl` in `retro-argo.yaml`'s harvest step
  (the RetroReportOverdue success-timestamp push). The diff IS observable (a curl in the action
  stream) but `retro-argo.yaml` had no fixture family yet — and NO FSM models the retro lane at
  all (dispatch-on-schedule machinery, roles.md; homelab#280 ruled: correct this wording, do not
  model the lane yet), so there is no FSM-side `replay:`/`unreplayed` declaration to point at —
  the first retro-lane fixture should record this step's world when it is built
  (jail-lane commit; the ratchet gained the file the same day, so the next PR touch pays properly).
- **retro-lane 2026-08-11 (three more jail-lane clause diffs, same fixture debt)** —
  `f791937` (AWS_REGION in tsenv), `6b1ece6` (harvest runs as root), `4db553e` (bounded worst-K
  slice + pipefail) each touched `retro-argo.yaml` direct-to-master; all observable; the standing
  entry below covers the debt — the first retro-lane fixture family pins ALL of it.
- **reviewer-git statuses:write (2026-08-18, the G01 flip PR#548)** — one permission field on
  the ESO `GithubAccessToken` generator (`reviewer-git.yaml`), widening the minted token so the
  iac-sentinel can post its required commit status under the reviewer identity. Declarative
  credential minting: no clause reads the manifest and no branch turns on it — the harness
  observes action streams, and this diff emits none (the sentinel's own posting behavior is
  script-side, `scripts/iac-sentinel.sh`, which is not a clause file).
- **guard stderr-fold fix (2026-08-11, homelab#237)** — the guard's busy-probe read kubectl's
  stderr "No resources found" as pod output (`2>&1`), refusing every fire since unsuspend; fixed
  to a split-stream read, both legs verified live from the jail (empty ns → idle, failing probe →
  busy). Observable (a kubectl call + refusal line) — the debt above stands: the first retro-lane
  fixture should pin BOTH the refusal legs and this empty-is-idle case (jail-lane commit).
- **retro-lane debt, PARTLY PAID (homelab#248)** — `fixtures/retro-cell-report-*` and
  `fixtures/retro-harvest-*` are the first retro-lane family: the cell's report-marker self-check
  (both verdicts) and the harvest's cell→filename slug plus its partial-run notice. They do NOT
  discharge the standing entry above — the **guard** (busy-probe legs, ledger delta) and the
  harvest's git/gh half are still unpinned (the retro fixtures are helper-level pins under
  merge-path-lint's "no FSM transition references" visibility line — no FSM models this lane,
  homelab#280). The next touch of either extends this family rather than opening a fourth
  register line. **Extended 2026-08-11 (homelab#268)** — `fixtures/retro-harvest-cell-errored`
  joins the family for the DAG's Error phase (see the declaration note above). **Extended
  2026-08-11 (homelab#269)** — `fixtures/retro-harvest-slug-collision` pins the other filename
  branch: two cells on ONE model under different harnesses (`claude:opus` / `goose:opus`) derive
  one slug, so the harvest disambiguates with the harness ON COLLISION ONLY; its sibling
  `retro-harvest-slug` is the regression proof that the ordinary path's names did not move. Still
  unpaid, and still this entry's debt: the **guard** (busy-probe legs, ledger delta) and the
  harvest's git/gh half.
- **homelab#536 (2026-08-18)** — the TOOL_GAP marker instruction (producer briefs + the janitor's
  sweep #6) touched two clause files: `coordinator/responder-argo.yaml` (HARD RULES) and
  `reviewer-session.sh` (pod-side `PROMPT`). Both diffs are LLM-PROMPT prose inside the `claude -p`
  invocations, OUTSIDE every `>>>REPLAY:` sentinel, so no extracted clause changes and no
  action-stream moves — the harness asserts a clause's `gh`/`kubectl` calls, and prompt text emits
  none. Evidence rather than assertion: the full suite (119) stayed green byte-identically on the
  branch. The reader half (janitor sweep in `agents/coordinator-session.sh` + the seeded inventory
  in the coordinator README) is not a clause file.
- **homelab#556 (2026-08-18)** — the reviewer STEP-0 prompt-text fix in `reviewer-session.sh`:
  the own-verdict-at-head precondition now counts only LIVE (non-DISMISSED) reviews
  (APPROVED/CHANGES_REQUESTED, the reflex breaker's filter), and the standing-aside dedup is
  re-keyed on a machine marker (`<!-- standing-aside head=<content-sha8> pre=<slug> -->`)
  instead of prose. Same shape as the #536 entry: LLM-PROMPT prose inside the `claude -p`
  invocation, OUTSIDE every `>>>REPLAY:` sentinel (the currency-gate and touches-check blocks
  extract byte-identically before/after), so no extracted clause changes and no action-stream
  moves — the harness asserts a clause's `gh`/`kubectl` calls, and prompt text emits none.

Adding a fixture, recording a world, and the ADR-103 ratchet rule are all in the workflow doc.
- **homelab#650 legs 1+2 (2026-08-19)** — the `/sentinel` endpoint block added to the agent-loop
  EventSource in `review-argo.yaml`: a pure Argo Events DECLARATION (port/endpoint/method — no
  clause shell, no branch, no action stream), consumed by the new `sentinel` Sensor
  (sentinel-argo.yaml). The harness asserts a clause's `gh`/`kubectl` calls and this diff emits
  none; the sibling endpoint additions (`/fix-verdict`, `/deploy-degraded`) predate the ratchet's
  clause-file list and carried no fixture for the same reason. The evaluation the Sensor submits
  is `scripts/iac-sentinel.sh` — script-side, not a clause file (the PR#548 register entry's
  precedent, one line up in this list's history).
- **homelab#443 re-review catch (2026-08-18)** — dropping `2>/dev/null` from the four
  `--pick-rail` command substitutions (`review-reflex.sh`, `agent-session.sh`'s worker/retro
  dispatch leg + the responder/fix-debounce argo YAMLs): a redirection-only change — `$(...)` captures stdout alone, so the rail value and
  every action stream are byte-identical before/after; the change only lets the latch's
  diagnostic stderr flow to pod logs again. The full suite (incl. the pick-rail fixtures,
  which stub the latch) passed unchanged — no clause logic moved, no fixture applies.
- **homelab#564 (2026-08-19)** — the two live HEREDOC-BACKTICK instances the new lint signature
  surfaced (`coordinator-session.sh:439`, `reviewer-session.sh:575`): comment-only rewording
  inside expanding heredoc bodies — backticks in an unquoted heredoc command-substitute even in
  `# comment` lines, silently deleting the fragment from the delivered manifest. No action
  stream changes (the manifests' comment TEXT is not asserted by any fixture); the full suite
  passed unchanged. The lint's new fixtures (`scripts/fixtures/prompt-transport/`) are the
  executable pin for the class.
- **homelab#919 (2026-08-25)** — added `homelab.io/ephemeral` toleration to the non-docker pod
  spec in `agents/agent-session.sh`. The toleration is a YAML fragment inside an unquoted heredoc
  (`cat <<EOF | kubectl create -f -`) that is NOT inside any `>>>REPLAY:` sentinel — the pod
  manifest is rendered inline, not as a callable block. No action stream changes (the kubectl
  create call is not stubbed by any fixture; the toleration only changes which nodes the
  scheduler considers, not what the script sends to the API). The full suite passes unchanged
  — no clause logic moved, no fixture applies.
- **homelab#867 (2026-08-26, PR #952)** — the #103 soft `topologySpreadConstraints` block
  extended to the `agents/coordinator/*-argo.yaml` workflow specs it had never reached, plus a
  soft `nodeAffinity` `preferredDuringSchedulingIgnoredDuringExecution` de-preference (weight
  10) for nodes labelled `node.longhorn.io/create-default-disk=true`. Same class as the #103
  entry that opens this register: pod *placement* declared to the kube-scheduler through
  `podSpecPatch` — no clause reads it, no branch turns on it, and the diff emits no action
  stream. Evidence rather than assertion — the full suite stays green on the change with every
  `expected/actions.txt` untouched.
- **homelab#974 (2026-08-26, PR #1000)** — `limits.memory` raised from `512Mi` to `1Gi` in
  `agents/coordinator/coordinate-argo.yaml` (the `coordinate` WorkflowTemplate's main
  container). A container resource declaration to the kubelet/scheduler — no clause reads it,
  no branch turns on it, and the diff emits no action stream. Same class as the #103 / #867
  placement-and-resources entries: the harness asserts a clause's `gh`/`kubectl` calls, and
  this diff emits none. Evidence rather than assertion — the full suite stays green on the
  change with every `expected/actions.txt` untouched.
- **homelab#1035 (2026-08-30, PR #1078)** — two rationale comments restored inside the `>>>REPLAY:config-defaults>>>` block of `agents/coordinator-scan.sh` (`REPO_MAX_WIP=3` citing ADR-097/TRACKS rule 1; `ISSUE_LIST_LIMIT=200` citing the homelab#840 24-day-invisible-queued-issue finding). Comment-only — no value, predicate, or control-flow changed, so the extracted clause values are byte-identical and no action stream moves. Evidence rather than assertion — `devbox run clause-replay` 298 passed, every `expected/actions.txt` untouched.
