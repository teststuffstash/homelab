# worlds/ — the named states the island's rows run in

Expected behaviour is a function of (system, world). This island's worlds are the ones its
harnesses already build; none is in the shared registry yet (`agents/replay/worlds/` holds only
`circles-29-tree`), so each is named here and points at where it lives. A row names its world in
the `world` column; a page whose rows share one world names it once above the table. Terms:
[glossary.md](../glossary.md).

## Harness worlds — a pinned clock and file seams

| world | where it is built | what it fixes |
|---|---|---|
| `dig-clock` | `agents/deep-dig-test.sh` (top: `DIG_NOW` = 2026-10-04T06:00:00Z, a stub `gh` serving `gh-search.json`) | the clock; Alertmanager as the file `DIG_AM_FILE`; Prometheus day reads as `DIG_PROM_DAY_DIR/day-N.json`; the window ConfigMap as `DIG_WINDOW_FILE`; prior findings as `DIG_PRIOR_FILE`; `docs/follow-ups.md` and `meta-state.md` as files under a temp `DIG_REPO`; params at their defaults (standing 6 h, recur 3 of 7 d, onset bucket 60 min, 4 groups, re-dig 7 d) unless a row says otherwise |
| `intake-bucket` | `agents/island-intake-test.sh` §selector --source dig (`NOW` = 2026-10-27T05:00:00Z) | the transcripts bucket as a directory (`INTAKE_TS_DIR`): six dig findings over 2026-10-10…26 (three name the gateway inside the 7-day lookback), receipts added row by row; `INTAKE_DAILY_MAX` 2 |
| `intake-bucket-s3` | the same section, `TS` served through a stub `s5cmd` that answers as Garage + s5cmd v2.3 do (observed in-cluster 2026-10-28: `<date> <time> <size> <key>` rows, an empty prefix = ERROR + exit 1) | the real S3 branch of the selector |
| `intake-precedence` | `agents/island-intake-test.sh` §island precedence | four findings whose text names, in turn, a router-pair alert, the gateway (and an `agents/` path), a mgmt-box alert, Longhorn |
| `issue-table` | `agents/island-intake-test.sh` §selector issues (`INTAKE_ISSUES_JSON`) | 30 open issues — titles, `Touches` blocks, labels, first comments, authors — each row's expected island derived from the selector's header contract |
| `responder-suite` | `agents/coordinator/responder-behaviour-test.sh` | the `respond` script extracted from the manifest, `/work/homelab` redirected, `gh`/`kubectl`/`claude`/`curl`/`git` recorders, the AgentStack read DENIED so routing resolves through the real `agents/stacks.json` |

## Fixture worlds — a replay fixture's own recorded `world/`

Every `agents/replay/fixtures/responder-*/<case>/` carries its recorded API answers under
`world/gh/` and `world/kubectl/` (the harness's read/write split: reads are served, writes are
recorded — [`agents/replay/README.md`](../../../../replay/README.md)). The fixture dir IS the
world's name: a row whose `fixture` cell is `responder-cause-line/valid` runs in that dir's world
and nothing else. Where several cases of one family share a base (the `responder-capture`
twins reuse `../uploads/bridge.sh`) the fixture says so in its `parts:`.

`⚑ gap`: the 12 responder families are N copied directories, not tables over named worlds — the
cleanup contract's move 2 (`mode: table`, [`agents/replay/README.md`](../../../../replay/README.md)
§The cleanup contract) has not reached them. A family converted to a table would make its
`rows.psv` id column the description cell of these pages, verbatim.

## The production world (what no row runs in)

The pods' real reads: Alertmanager at `kube-prometheus-stack-alertmanager.monitoring.svc:9093`,
Prometheus at `…-prometheus.monitoring.svc:9090`, the `responder-seen` / `responder-window`
ConfigMaps in `agent-coordinator`, the `agent-transcripts` bucket on Garage, GitHub through the
coordinator's `GH_TOKEN`, the gateway at `POST /sessions`. A row is never stated against it; a
fact only it can show is a closeout observation, not a row.
