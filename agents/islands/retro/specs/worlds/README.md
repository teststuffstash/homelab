# worlds/ — the fixture states the retro's rows run in

A **world** is a named fixture state: expected behaviour is a function of (system, world), so every
row names its world. The retro's worlds are the replay harness's fixture dirs
([`agents/replay/README.md`](../../../../replay/README.md)) plus the three in-process unittest suites
`agents/retro-cadence-test.sh` runs. The shared replay worlds under `agents/replay/worlds/` hold
none of the retro's state (only `circles-29-tree`, a coordinator world), so no name is reused.
Names here are fixture names, not production ones: the bucket, the Prometheus and GitHub are stubs.

| world | fixture | what it fixes for every row |
|---|---|---|
| `guard-bridge` | [`retro-quiet-guard`](../../../../replay/fixtures/retro-quiet-guard/) (`bridge.sh`, `rows.psv`) | the guard step's clause between its REPLAY markers, extracted from `retro-argo.yaml`; `prepare` replaced by an exit code (`PREP_RC`), each pushgateway attempt by an exit code (`CURL_RC_1`, `CURL_RC_2`), the Prometheus answer by `PROM_VALUE` (`1`, `0`, `absent`, `error`, `down`) fed through the real `retro_guard_expr.py` |
| `cell-bridge` | [`retro-gateway-cell`](../../../../replay/fixtures/retro-gateway-cell/) | `retro-session.sh`'s `retro-cell-path` + `retro-gateway-cell` clauses; `agent-session.sh` replaced by a recorder whose exit code is `HANDOFF_RC`; run id `r10` |
| `cell-report-logs` | [`retro-cell-report/<case>`](../../../../replay/fixtures/retro-cell-report/) | one committed `ride.log` per case (`present`, `missing`, `skeleton`, `multi-block`, `longlog`) run through the cell's self-check clause and the real `retro-report-floor.sh` |
| `key-world` | [`retro-key/<case>`](../../../../replay/fixtures/retro-key/) | the `retro-session-key` clause with `kubectl` and `estimate_budget.py --emit-cr` stubbed (the CR rendered inline, block-style, labels-first) |
| `harvest-logs` | [`retro-harvest`](../../../../replay/fixtures/retro-harvest/) (`logs/`) | the `retro-harvest-slug` clause over committed ride logs named by `LOG_A_NAME` / `LOG_B_NAME`, `harnessA=claude`, `harnessB=goose` unless the row overrides |
| `harvest-push-bridge` | [`retro-harvest-push`](../../../../replay/fixtures/retro-harvest-push/) | the `retro-harvest-push` clause with `gh pr list` answers (`OPEN_PR`, `MERGED_PR`) and the report diff vs master (`GIT_DIFF_RC`) stubbed |
| `push-belt-bridge` | [`retro-push-belt`](../../../../replay/fixtures/retro-push-belt/) | the `retro-push-belt` clause; each pushgateway attempt an exit code |
| `local-store` | `agents/retro-pipeline-test.py` (suite [`retro-activity-window`](../../../../replay/fixtures/retro-activity-window/)) | `retro_pipeline.py` against a temporary `--store` directory (the bucket's local twin: same keys under `_retro/`), `retro_activity.py` and `retro_findings.py` run for real, GitHub reads stubbed |
| `fake-github` | `agents/retro-activity-test.py`, `agents/retro-findings-test.py` (same suite) | the collector's `api()` / the reconciler's `fetch` replaced by in-memory answers; no network |
| `rank-ledger` | [`retro-rank-snapshot-exclusion`](../../../../replay/fixtures/retro-rank-snapshot-exclusion/) | a small `_ledger.jsonl` (one `snapshot: true` row that would rank first, int and array `rounds`), `gh` served from a PATH stub — the legacy ranker only |

Production state these worlds stand in for: the bucket `agent-transcripts` on Garage (`_retro/`,
`_ledger.jsonl`), Prometheus `prometheus-operated.monitoring:9090`, the pushgateway
`prometheus-pushgateway.monitoring:9091`, the agent-gateway, and GitHub through the `retro-git`
(read) and `coordinator-git` (write) identities.
