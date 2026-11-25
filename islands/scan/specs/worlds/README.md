# worlds/ — the named states the scan's rows run in

A **world** is a named fixture state: expected behaviour is a function of (system, world), so a
row that does not name its world is lying by omission. For this island a world is a set of
**recorded or constructed answers** the replay stubs serve — `gh` (issue/PR lists, views, REST
endpoints) and `kubectl` (pods, workflows) — plus, where a row varies it, an **env condition**
(a stub failure injection, a knob). The replay worlds — the registry and family worlds tabled below — live where the harness keeps
them; nothing of them is copied here. Mechanism: [agents/replay/README.md](../../../../agents/replay/README.md) (§The cleanup
contract, moves 1–2: named registry worlds, table mode, `patches/*.jq` that must change the
base). Terms: [../glossary.md](../glossary.md), [docs/glossary.md](../../../../docs/glossary.md).

## Recorded worlds (`worlds/<name>/` — here)

A **recorded world** is a directory beside this page holding the whole answer of each GitHub read a
surface makes, one file per read, as `gh` printed it: no field removed. Its `provenance.yaml` names
the repo, the item numbers, each read (the `gh` argv, REST path included), the recording time and
the recorder's commit. The recorder is
[`scripts/record_world.py`](../../scripts/record_world.py); a world is re-recorded, never hand-edited. A read a surface starts to make after a world was recorded is added by the recorder for the world's recorded items (`--add`), with its own recording time and recorder commit in `provenance.yaml`; the reads already recorded are not performed again.

- **Public repos only, no credential.** The recorder reads the repo's visibility first and refuses a
  repo GitHub reports as private. A world holds response bodies only: no request or response
  header, no token.
- **A write is never recorded by performing it.** Each write the surface issues is declared in
  `provenance.yaml` and answered by a hand-written file, `writes/<op>.<status>.json`. Each answer
  validates against that operation's response schema, extracted from GitHub's published REST
  description into `schemas/<op>.<status>.json`; `provenance.yaml` names the description's commit.
  `gh pr merge --auto` prints no JSON: its answer is an exit status. A world that declares no write has no `schemas/` and no `writes/` directory, and its `provenance.yaml` names no description.
- **A row's state is the recorded answer with the row's cells applied as value overrides.** An
  override changes the value of a field that exists, or adds a list element copied from a recorded
  element of the same list. It never removes a field.
- **Reading is strict on both sides.** The world answers only a read it holds: an unrecorded read
  fails the case. A component that reads an answer lacking a field its page's schema requires
  treats the answer as unreadable and issues no write; it never substitutes a default.

| world | what it is | used by |
|---|---|---|
| `pr-handoff` | one pull request of `teststuffstash/homelab` as the major handoff reads it, recorded whole | SCAN-HANDOFF-GATE, SCAN-HANDOFF-ARM (from child 3 of the Goal) |
| `pr-board` | the open pull requests of `teststuffstash/homelab` as the updater reads them, with the per-PR reads, recorded whole | SCAN-UPDATER-PICK, -UNSTRAND, -CONFLICT, -RENOVATE (from child 4 of the Goal) |
| `pr-merges` | the commits of one pull request of `teststuffstash/homelab` (#3615) as the PR view and the pull-commits read list them, recorded whole: hand-titled two-parent merges beside GitHub-titled ones | the [merge commit](../glossary.md#merge-commit) definition's wire fact; no row |
| `goal-checkpoint` | Goal #3118 of `teststuffstash/homelab` and its assembly pull request #3270 as the checkpoint decision reads them, recorded whole after the pull request merged; a row's open assembly pull request is a derived element of the recorded open list | SCAN-CLAUSE-GOAL, the trigger (b) hold (from child 2 of the Goal) |

## Registry worlds (shared by name — `agents/replay/worlds/`)

| world | what it is | used by |
|---|---|---|
| `circles-29-tree` | the live circles Goal #29 tree as recorded 2026-08-07..09 (reconstructed provenance): the goal, its children, post-launch shapes, merged-PR bodies, the ledger scrape | [SCAN-CLAUSE-GOAL](../scan-decision.md#scan-clause-goal) (`harvest` rows), [SCAN-CLAUSE-PHANTOM](../scan-decision.md#scan-clause-phantom) (`c4c5-*`) |

## Family worlds (fixture-local `worlds/<name>/`, named in `rows.psv`)

| world | family | what it fixes |
|---|---|---|
| `board` | `updater` | one repo, CLEAN base: `#90` armed ∧ CLEAN, `#91` un-armed ∧ BEHIND — the armed-only witness; every PR carries `baseRefName` |
| `base` | `c9-rearm` | worker-authored PRs on master/`goal/**`, one un-armed, one witness |
| `approved` / `recorded-738` | `major-handoff` | oracle-fleet#738 with the bot's APPROVED at head carrying the four headings / as recorded live with `reviews: []` (2026-09-25) |
| `agent-runtime-guarded`, `agent-runtime-guarded-large`, `oracle-fleet-none` | `scan-guarded` | a remote repo's guard declaration as its `ci.yaml` serves it through the API / a large file / no declaration |
| `verdict` / `inert` | `c4c5-infeasible` | an `AGENT_INFEASIBLE:` line as the first characters of a comment / quoted mid-body |
| `line1` | `blocked-on-anchor` | a `blocked-on:` marker on the ruling comment's first line |
| `open-pre`, `terminal` | `goal` | an open Goal before its checkpoint with bare / dispositioned members / a closed Goal |
| `homelab-278-tree`, `circles-constructed-parents` | `goal-ancestor` | a recorded deep tree (Goal #278) / constructed parent chains with and without `Budget:` |
| `deep-sprout`, `master-inert` | `harvest` | a sprout several levels below its Goal / a master-lane PR with no Goal ancestor |
| `pair`, `across`, `spread`, `unknown`, `keyclass`, `noprovider`, `mixed-provider`, `mixed-model` | `fleet-reader-rekey` | `AGENT_STRIKE` populations: one (model, provider) pair / one model across providers / spread across both / unattributed / key-class / no provider / mixed |
| the clause-coverage world | `clause-coverage` | one issue per enumerated state, `#80`–`#88` (queued, queued-goal, in-progress, review, review-no-fix, review-frozen, blocked, error, done) |
| (none — env only) | `scan-lane-walk`, `queued-body-tsv`, `reflex-breaker`, `live-worker-pod` | the row's `env` (`ROW=…`, `IN_V_HEAD=…`) constructs the state inside the bridge |

## Env conditions (cross-cutting)

| condition | meaning |
|---|---|
| `STUB_GH=fail`, `STUB_GH_<call-slug>=fail` | that `gh` call fails (rule #6 rows: an unreadable probe never becomes a write) |
| `STUB_GH_GRAPHQL=drained` | every GraphQL mutation fails "API rate limit already exceeded for installation …" while REST serves — the FU-290 drain shape; label writes must still land ([SCAN-GH-LABELS](../github-grammar.md#scan-gh-labels)) |
| `STUB_KUBECTL=fail` | the pod/workflow read fails |
| `UPDATER_MERGE_READY_ONLY=0` | the pre-#1452 updater pick, kept for the L-scenario comparison |
