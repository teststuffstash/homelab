# worlds/ — the states the retro's rows run in

A **world** is a named state — a recorded world (§Recorded worlds) or one of the old members' fixture states: expected behaviour is a function of (system, world), so every
row names its world. The fixture worlds are the replay harness's fixture dirs
([`agents/replay/README.md`](../../../../agents/replay/README.md)) plus the three in-process unittest suites
`agents/retro-cadence-test.sh` runs. The shared replay worlds under `agents/replay/worlds/` hold
none of the retro's state (only `circles-29-tree`, a coordinator world), so no name is reused.
The fixture worlds' names are fixture names, not production ones: there the bucket, the Prometheus and GitHub are stubs.

| world | fixture | what it fixes for every row |
|---|---|---|
| `prom-instant` | [`prom-instant/`](prom-instant/) — recorded | the answers of Prometheus `GET /api/v1/query`, one entry per `PROM_VALUE` cell: `1`, `0`, `absent`, `error` recorded, `down` declared (no answer) |
| `guard-bridge` | [`retro-quiet-guard`](../../../../agents/replay/fixtures/retro-quiet-guard/) (`bridge.sh`, `rows.psv`) | the guard step's clause between its REPLAY markers, extracted from `retro-argo.yaml`; `prepare` replaced by an exit code (`PREP_RC`), each pushgateway attempt by an exit code (`CURL_RC_1`, `CURL_RC_2`), the Prometheus answer by `PROM_VALUE` (`1`, `0`, `absent`, `error`, `down`) fed through the real `retro_guard_expr.py` |
| `cell-bridge` | [`retro-gateway-cell`](../../../../agents/replay/fixtures/retro-gateway-cell/) | `retro-session.sh`'s `retro-cell-path` + `retro-gateway-cell` clauses; `agent-session.sh` replaced by a recorder whose exit code is `HANDOFF_RC`; run id `r10` |
| `cell-report-logs` | [`retro-cell-report/<case>`](../../../../agents/replay/fixtures/retro-cell-report/) | one committed `ride.log` per case (`present`, `missing`, `skeleton`, `multi-block`, `longlog`) run through the cell's self-check clause and the real `retro-report-floor.sh` |
| `key-world` | [`retro-key/<case>`](../../../../agents/replay/fixtures/retro-key/) | the `retro-session-key` clause with `kubectl` and `estimate_budget.py --emit-cr` stubbed (the CR rendered inline, block-style, labels-first) |
| `harvest-logs` | [`retro-harvest`](../../../../agents/replay/fixtures/retro-harvest/) (`logs/`) | the `retro-harvest-slug` clause over committed ride logs named by `LOG_A_NAME` / `LOG_B_NAME`, `harnessA=claude`, `harnessB=goose` unless the row overrides |
| `harvest-push-bridge` | [`retro-harvest-push`](../../../../agents/replay/fixtures/retro-harvest-push/) | the `retro-harvest-push` clause with `gh pr list` answers (`OPEN_PR`, `MERGED_PR`) and the report diff vs master (`GIT_DIFF_RC`) stubbed |
| `push-belt-bridge` | [`retro-push-belt`](../../../../agents/replay/fixtures/retro-push-belt/) | the `retro-push-belt` clause; each pushgateway attempt an exit code |
| `local-store` | `agents/retro-pipeline-test.py` (suite [`retro-activity-window`](../../../../agents/replay/fixtures/retro-activity-window/)) | `retro_pipeline.py` against a temporary `--store` directory (the bucket's local twin: same keys under `_retro/`), `retro_activity.py` and `retro_findings.py` run for real, GitHub reads stubbed |
| `fake-github` | `agents/retro-activity-test.py`, `agents/retro-findings-test.py` (same suite) | the collector's `api()` / the reconciler's `fetch` replaced by in-memory answers; no network |
| `rank-ledger` | [`retro-rank-snapshot-exclusion`](../../../../agents/replay/fixtures/retro-rank-snapshot-exclusion/) | a small `_ledger.jsonl` (one `snapshot: true` row that would rank first, int and array `rounds`), `gh` served from a PATH stub — the legacy ranker only |

The rows after `prom-instant` are the old members' fixture states: the comparison runs in them, and a
requirement page that still names one is not yet tested from a recorded world.

Production state these worlds stand in for: the bucket `agent-transcripts` on Garage (`_retro/`,
`_ledger.jsonl`), Prometheus `prometheus-operated.monitoring:9090`, the pushgateway
`prometheus-pushgateway.monitoring:9091`, the agent-gateway, and GitHub through the `retro-git`
(read) and `coordinator-git` (write) identities.

## Recorded worlds

A recorded world is a directory `worlds/<world>/` of answers, built under
[`islands/README.md` §Built from the specs, never copied](https://github.com/teststuffstash/homelab/blob/master/islands/README.md#built-from-the-specs-never-copied)
rule 2. One answer is one JSON file `<world>/<entry>.json` with these fields, all required:

| field | holds |
|---|---|
| `surface` | which surface answered (`prometheus`) |
| `request` | `method`, `path`, `query` (the query parameters, an object of strings) — no host, no credential |
| `recorded_at` | the time of the GET, UTC, RFC 3339 |
| `recorded_by` | who recorded it |
| `status` | the HTTP status, or `null` when the surface gave no answer |
| `body` | the answer's bytes verbatim as one string (`""` allowed), or `null` |

`status` and `body` are both `null` (a declared entry: no answer) or both set. The reader
(`src/retro_island/worlds.py`) is strict: a missing field, an unknown field or a field of the wrong
type is an error, never a default. The recorder (`src/retro_island/record.py`) does one GET per run.
