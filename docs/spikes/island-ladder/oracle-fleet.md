# oracle-fleet — position on the island maturity ladder

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca` and
> `oracle-fleet c3f7ee1` (the local clone, possibly a few commits behind origin), 2026-11-22.
> **A reading from outside.** The oracle stack keeps its own facts, read set and roadmap in its
> own repo and has its own seat ([ADR-160](../../adr.md)). Nothing here is an edit to oracle-fleet;
> every "next step" is a suggestion for the oracle seat. Oracle-fleet paths below are relative to
> that repo's root (`teststuffstash/oracle-fleet`).

## What it is

A production service: MCP servers that answer Estonian law lookups from a built SQLite corpus, with
citations (`chassis/`, `mcps/riigiteataja/`, `gateway/`, the Helm chart `chart/`); deployment truth
sits in the private oracle-iac repo. It replaces no old platform member, so R6 does not fit. Live
code is the island: every master merge is a release that Kargo promotes to prod without a person.

## Position

| Rung | State | Evidence | Open item |
|---|---|---|---|
| R1 Boundary | reached | one repo; `README.md` layout table; intake facts `docs/intake.md` (320 lines, declared by the oracle-iac claim line `repos[].intake.facts`); consumer contract = the MCP surface `specs/tools/*.schema.json` | nothing filed |
| R2 Specs | reached | `docs/process/README.md` pins allure-behavior-snippets **v0.6.9** (`SNIPPETS_WHEEL` in `scripts/lib/snippets.sh`, sha256-checked); prefixes `RT-`, `ING-RT-`, `SRV-`, `DEP-`, `FB-`; 15 spec pages under `specs/` | nothing filed |
| R3 Evidence | reached | `tests/evidence.py` `rule("<ID>")`; rows are the test argnames (`docs/process/conventions.md` §Evidence row identity); incompleteness marks counted: 6 `🚧 WIP → #N` (one with an empty `#`, in `specs/server/mcp-conformance.md`), 18 `⚑ gap`, 13 `_Evidence: none yet_` markers | nothing filed for the empty `🚧 WIP → #` |
| R4 Worlds | reached | `specs/worlds/README.md`: 14 world YAMLs + `ert-mock`; 5 quarried with provenance headers + 8 verbatim wire members in `specs/worlds/wire/`; strict loader `chassis/worlds.py` round-trip in `tests/test_worlds.py`; wire reconciliation rows in `tests/test_parse.py` | `spec-process-redesign.md` §4 says mining is under-practiced; nothing filed |
| R5 Gates | reached | `scripts/ci.sh` (the required `ci` check) runs `spec-gate.mjs`, `spec-evidence-lint.py` (checks A–J), `spec-join-ratchet.py`, `spec-hygiene-ratchet.py`; baselines: join = 90 rules, **all five counts 0**; hygiene = **empty set**; evidence-lint G/H/I = **9 / 73 / 53**; specs reviewer is the second required approval (ADR-OF-008 (2)) | lowering G/H/I: nothing filed |
| R6 Replaces the old | does not fit | a stack built new; no replay family or old member | — |
| R7 Metrics | reached | `chart/alerts/`: 5 rule files, 11 alerts, each with a sibling `*.promtool-test.yaml` (enforced by `scripts/check-alert-fixtures.sh` + real `promtool test` in `ci.sh`); dashboards `chart/dashboards/oracle-gateway.json`, `oracle-feedback.json`; facts §Sources names the Prometheus reads; no recording rules (`grep record: chart/` empty) | zero-hit share not a panel (`docs/delivery-loop.md` §KPIs); nothing filed found |
| R8 Feedback loop | partial | every piece is written (below), but the briefs that drive it are `PROPOSED` (`.agents/metric-finding.md`, `intake-experiment.md`, `closeout.md` §Release verdict); `gateway/experiments/experiments.json` is `{"required": [], "experiments": {}}` — no release carries a claim today | #917 (`agent/blocked`, DEP-SHADOW chart half, per meta-state) |
| R9 Intake | partial | claim line merged (oracle-iac#1196); dry run passed 11-21 (`docs/process/meta-state.md`); 30 issues carry `intake/hold` (gh, 39 open); waits/escapes: no oracle record found (`grep -i escape docs/intake.md` empty) | first 05:00Z sitting receipt unread (meta-state NEXT) |
| R10 Learns | partial | facts file grew from sittings: PR #1105 fixed facts after the dry run; worked examples cite the issue that taught them (#1040, #1056, #1086); the weekly `feedback-triage` retro series (`.agents/feedback-triage.md`) improves `specs/tools/feedback-rules.yaml`; `spec-process-redesign.md` §The data log | no loop over intake stalls yet; nothing filed |

## Not on the draft ladder

- **Release and rollout:** Kargo Stages `shadow` (`release-verify`, DEP-VERIFY) and `prod`
  (`release-observe` over prod traffic, DEP-OBSERVE-GUARDS); `.agents/prod-rollback.md` because Kargo
  OSS has no native rollback; alert `KargoProdVerificationFailed` lives in oracle-iac.
- **A data boundary:** the corpus moves only at an attended regen (ADR-OF-005, "a regen is never an
  issue edge"); `.agents/closeout.md` defines done as deployed, with a corpus-side special case.
- **Weighing before queue** (`docs/intake.md` §What you read): wire token cost from the wire ledger
  (`specs/server/wire-ledger.md`), model usability, payload size, standing contract rules.
- **Whole-unit reads:** `docs/process/read-map.yaml` splits the corpus into 6 units of 30–70k tokens
  read whole; the platform's gateway read stops at the requirement section.
- **Evidence review as a separate lens** (`.agents/evidence-review.md`, PROPOSED, seat prototype).
- **Agentic probes** of real model clients (`.agents/probe.md`, `probe-class2.md`; `probes/`).
- **Privacy and retention alerts** (`edge-privacy`, `retention-ledger`), tied to a public page by a test.

## The island's own items

- Product roadmap `docs/roadmap.md`: R1 one skill file; R2 three research missions (määrus
  resolution first, then English corpus, then link layer); three shapes ruled off (proxy, source
  index, router). Not queued by its own words; nothing filed per item found.
- Serve MCP revision 2026-07-28 beside the legacy era: post-launch bucket #1069; #902 in progress.
- Snapshot contracts split: post-launch bucket #956.
- Ingest holds: #827 DELAYED, #820 parked (meta-state).

**What a sitting would gain from `docs/roadmap.md`:** it is not in the facts file's read set. A
sitting would learn which shapes are ruled off (so a feedback row asking for a proxy or an index is a
close, not a seat) and that research precedes a build Goal. **Nothing in the repo plays a maturity
roadmap.** `TRACKS.md` is ownership and WIP rules, `read-map.yaml` is a read map, meta-state holds
are a flight recorder; `spec-process-redesign.md` (status "NOT being implemented yet") is the
nearest thing to a process roadmap.

## In flight

- R3/R7: #902 gateway accepts protocol 2025-06-18 (`agent/in-progress`); #1056 rejected-protocol
  share alert (`agent-fix`; the #1069 bucket title names it).
- R8: #917 (`agent/blocked`, per meta-state); #1095, #1001, #866, #865, #826 carry `agent/done` but
  are open (closeout waits on prod or regen per `closeout.md`).
- R9: 30 held issues (`intake/hold`); 0 open Goals (only the post-launch buckets #1069, #956).
- PRs: Renovate #965, #1051, #1098, parked until homelab's dependency-upgrade rules land (meta-state).

## Next steps, in order

1. R9 — read the first sitting's receipt; carries: meta-state NEXT; waits on the 05:00Z sitting.
2. R8 — settle which experiment format and reader oracle uses: its own `intake-experiment.md` plus
   Kargo `release-claim`, or the platform's (below). Nothing filed; waits on the oracle seat's call.
   Recommendation: keep the format shared (already so) and mark the facts §Sources rows that feed it.
3. R8 — codeowner read of the four PROPOSED briefs; nothing filed; waits on the operator.
4. R8 — first release that ships a non-empty `experiments.json` and gets a closeout verdict; carries:
   #917 for the shadow half; waits on step 3.
5. R9 — record waits and escapes for oracle (the platform selectors exist); nothing filed.
6. R5 — lower the evidence-lint G/H/I baseline (135 module counts); nothing filed; no wait.
7. R10 — a learning loop over oracle's intake stalls; nothing filed; waits on step 5's records.

## What it can lend, what it should borrow

Lend (as is, paths in oracle-fleet):
- World mining chain: `scripts/census-ert-corpus.py --find`, `corpus-sweep.py`, `world-quarry.py`
  (provenance header: aktViide, dump sha256, loemind, extraction date), `corpus-member.py`
  (stdlib-only read door for pods), `world-to-wiremock.py` (verbatim bytes as WireMock stubs). It
  mines from a 252k-member upstream snapshot by shape predicate, smallest specimen first. The scan
  island's recorder ([worlds README](../../../islands/scan/specs/worlds/README.md),
  `islands/scan/scripts/record_world.py`) records whole `gh` answers per read, writes answered by
  schema-checked hand files. Both refuse invented data and edits in place; oracle's adds the census
  and a reconciliation test against the parser, scan's adds strict unrecorded-read failure.
- Gates: `scripts/spec-join-ratchet.py`, `spec-hygiene-ratchet.py`, `spec-evidence-lint.py`,
  `check-alert-fixtures.sh`, `kpi_backtest.py`.
- Already lent: the experiment block format, taken unchanged by
  [`experiment.py`](../../../islands/intake/scripts/experiment.py) ("from the stack that defines it").
- `read-map.yaml` (whole-unit reads) and the weighing list.

Borrow:
- Wait and escape records ([intake rules](../../../islands/intake/rules/intake.md) `wait:` /
  `escape:` inputs, `intake-wait.md`, `intake-escape.md`, `intake-wait-ledger.py`).
- Scan's strict-read rule: an unrecorded read fails the case.
- Its facts file could mark §Sources rows with the note `experiment`, as
  `docs/intake/router-pair.md` does.

## Three-group sort

| Item | Group | Reason |
|---|---|---|
| R1, R2, R3, R5 | common | the snippets process and its gates are repo-agnostic |
| R4 world mining | common (method) / island-only (census, quarry) | "mined, never invented" applies anywhere; the tools read Riigi Teataja dumps |
| R6 | platform-common | only islands that replace an old member |
| R7 alerts + promtool + dashboard | common | any island emits series |
| R7 privacy/retention alerts | stack-common | a public privacy page and user data |
| R8 alert → issue → intake | common | platform has the same shape |
| R8 release, Kargo `prod`, prod-traffic experiments, closeout verdict | stack-common | needs releases and real traffic |
| Feedback rows from users (`give_feedback`, gold rows) | stack-common | needs real users |
| Corpus regen boundary | stack-common | a built data artifact |
| R9 intake, R10 learning | common | |
| Weighing (token cost, wire ledger) | island-only | an MCP wire surface |
| `read-map.yaml` whole-unit reads | common | any island with a large spec corpus |
| Product roadmap items, #1069, #956 | island-only | product scope |

## Not verified

- Whether the 11-22 05:00Z sitting ran (its receipt is in S3; no cluster or bucket reads allowed).
- Whether a platform sitting writes `Experiment: none` for oracle: the platform rules take the claim
  from a §Sources row noted `experiment`, oracle's facts mark none, and `experiment-read.sh` reads
  "the platform repo"; I read rule text only.
- Live alert state, Kargo Stage state and prod version (no cluster queries).
- Issue-level filings behind each open item beyond the 5 `gh` calls made.
