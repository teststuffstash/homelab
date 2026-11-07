# worlds/ — the named states the scan's rows run in

A **world** is a named fixture state: expected behaviour is a function of (system, world), so a
row that does not name its world is lying by omission. For this island a world is a set of
**recorded or constructed answers** the replay stubs serve — `gh` (issue/PR lists, views, REST
endpoints) and `kubectl` (pods, workflows) — plus, where a row varies it, an **env condition**
(a stub failure injection, a knob). The worlds live where the harness keeps them; nothing is
copied here. Mechanism: [agents/replay/README.md](../../../../replay/README.md) (§The cleanup
contract, moves 1–2: named registry worlds, table mode, `patches/*.jq` that must change the
base). Terms: [../glossary.md](../glossary.md), [docs/glossary.md](../../../../../docs/glossary.md).

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
