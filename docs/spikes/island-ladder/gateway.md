# Gateway — position on the island maturity ladder

> Part of the island-ladder spike ([README](README.md)). Read at homelab `f1be04ca`, 2026-11-22.

## What it is

The agent-gateway is the fleet's LLM egress gateway: the credential boundary (a pod holds a
session token, never a key), per-session model resolution from `policy.json`, and four rails
(anthropic, openrouter, opencode, codex), plus the catalog, tier evidence and the wire record
([README](../../../gateway/README.md)). It replaces the old router
([`openrouter-proxy`](../../../argocd/resources/openrouter-proxy/)), which still runs beside it.
Live code reads it: platform-stack worker admission (`AGENT_GATEWAY=sessions`,
`agents/coordinator-session.sh:698`) and the retro launcher (`agents/retro-session.sh:240`). It sits
at `gateway/`, not under `islands/`, and was built spec-first with no replay fixtures of its own.

## Position

| Rung | State | Evidence | Open item |
|---|---|---|---|
| R1 Boundary | reached | one directory `gateway/` with its own devbox/uv lock; the README names the old router and points the contract at `specs/`; facts file [`docs/intake/gateway.md`](../../intake/gateway.md) | nothing filed |
| R2 Specs | reached | [`specs/README.md`](../../../gateway/specs/README.md) pins RULES/CONVENTIONS @ v0.6.9 (also `gateway/scripts/lib/snippets.sh`); 38 `GW-` requirements across 8 endpoint pages + `access.md`; each page has a schema twin | nothing filed |
| R3 Evidence | reached (residue) | `devbox run test` here: exit 0; `evidence.json` holds 1323 rule-labelled rows over 39 rules; `spec_gate.py`: "38 requirements, 0 red, 32 warnings", one of them "251 test rows carry no @rule marker"; 105 `🚧`/`⚑` marks on the spec pages | nothing filed for the 251 unlabelled rows |
| R4 Worlds | partial | the recorder is built: GW-WIRE-RECORD/-VIEW/-PROBE/-QUARRY ([`wire.md`](../../../gateway/specs/endpoints/wire.md)), `src/agent_gateway/wire.py`, `scripts/wire-quarry.py`; #3300's assembly PR #3615 merged. But `find gateway -name '*provenance*'` returns nothing: every fixture under `gateway/tests/fixtures/` is hand-cut; no `wire.json` declarations file in `argocd/resources/agent-gateway/` | #3300 (post-launch, bucket #3328); #3304 (worker recipe reads the door); provenance lint is a `⚑ gap` on GW-WIRE-QUARRY, "not yet filed" |
| R5 Gates | reached | `.github/workflows/ci.yaml:727` runs `devbox run gateway-ci` (`scripts/diff-ci.sh:97`); join baseline `gateway/scripts/spec-join-baseline.json`: 34 rules, every code 0; hygiene baseline `spec-hygiene-baseline.json`: empty list; specs reviewer is the second approval (facts file, ADR-155) — live on PR #3590 (`homelab-specs-reviewer` CHANGES_REQUESTED) | nothing filed |
| R6 Replaces the old | partial | still on the old router: `/route` for non-platform stacks (`agents/agent-session.sh:355`, `agents/resolve-model.sh:57`); the coordinator's and reviewer's own `/anthropic` base URL (`agents/coordinator-session.sh:746`, `agents/reviewer-session.sh:378`); `/loop-git-token` and `/git-token` (`coordinator-session.sh:234`); `/router-status` (`agents/coordinator-scan.sh:114`); the subscription latch (`agents/subscription-latch.sh:27`); `/report`, `/search`, `/rotation`, `/coordinate` handlers in `openrouter-proxy.py`. No parity record exists; `/route` compatibility and the git broker are `⚑ gap` rows (specs README, rule 10) | FU-270 (pointer); FU-269 (git broker out); no parity issue filed |
| R7 Metrics | partial | ~45 `gateway_*` families in `src/` (GW-METRICS); 11 alerts in [`prometheusrule.yaml`](../../../argocd/resources/agent-gateway/prometheusrule.yaml) with 6 `*.promtool-test` files beside it; the facts file names the gauges and the alert rules as reads. No dashboard (the old router ships `dashboard-subscription.json`); no symptom alerts on request outcomes; release not on `/healthz` | #3503 (dashboard), #3504 (outcome alerts), #3501 (release on `/healthz`) — all `agent/blocked` |
| R8 Feedback loop | partial | dig findings route to the island (`islands/intake/scripts/intake-select.sh --source dig`); the intake experiment loader exists (`islands/intake/scripts/experiment.py`, Goal #3586 assembly #3637); no gateway change has yet carried a claim to a prod verdict | #3505 (blocked-on #3504, which waits on #3088) |
| R9 Intake | reached | the first island in `intake-select.sh` (default `--island gateway`); runs in CronWorkflow `island-intake`; recorded wait cases in `islands/intake/tests/fixtures/wait-cases/` (3108, 3145, 3231, 3296, 3505, 3533, 3538, …); `IslandIntakeStale` per island | nothing filed |
| R10 Learns | partial | `intake-wait-ledger.py` tallies wait rule lines; an observed escape became a rules item (#3655, escape class B, PRs #3511/#3564). Whether a gateway-specific facts or rules change came from the ledger was not traced | #3655 |

## Not on the draft ladder

- **Wire capture of live traffic** (GW-CODEX-CAPTURE, `GET /sessions/{id}/capture`): a scoped
  four-boundary recording of a real ride. No rung covers recording production behaviour, as opposed
  to vendor answers.
- **The specs site** (`gateway/mkdocs.yml`, `scripts/specs-build.sh`, `scripts/e2e-specs-site.sh`,
  lychee): rows joined to the run's Allure report, published per PR. R5 names gates, not a site.
- **Evidence published to own storage** (`scripts/evidence-publish.sh`, bucket `gateway-specs`).
- **A deploy contract**: an image bump rolls the single Recreate replica; a key new to the policy
  loader lands one PR after the image that reads it (README §Test). No rung covers rollout safety.
- **Runtime rulings in policy** (tiers, bands, caps) and the entry canary per catalog refresh —
  production self-tests rather than test-suite evidence.
- **High Availability** (FU-271): one replica; no rung covers redundancy.

## The island's own items

The operator's five, plus what is this island's alone:

1. **Reach parity with the old router** (R6) — FU-270, FU-269; no parity or retirement issue filed.
   Parity here means: every route the old router still serves (list in R6) is either served by the
   gateway or ruled out of scope, and the coordinator/reviewer pods and the oracle stack admit through
   `POST /sessions`.
2. **Have specs** (R2) — reached.
3. **Spec cleanups** — the 251 rows without `@rule`, six `x-requirements` warnings on
   `sessions.schema.json` naming rules headed on other pages, the split candidates `spec_gate.py`
   prints, the hand-cut fixtures with no provenance sidecar. Nothing filed for any of them; the `||`
   divider migration is done (no page carries one).
4. **Take world mining from scan** (R4) — see below; nothing filed beyond #3300's tree.
5. **Better metrics** (R7, R8) — #3501, #3503, #3504, #3505.

Island-only beyond the five: runtime tier lists (#3305, #3309/PR #3590, #3231, #3329), Go account
headroom (#3118, bucket #3127), codex catalog and its entry canary (#3296, #3310, #3145), the Go
catalog's broken sources (#3533, #3538, #3293), tier residue (#2977), caller ServiceAccount binding
(#2684), goose/opencode env evidence out of CI (#2650), High Availability (FU-271).

**What "taking world mining from scan" means here.** Scan's recorded world is a directory per
world holding the whole answer of every read, `provenance.yaml` naming argv, time and recorder
commit, writes answered by schema-validated files, overrides that never remove a field, and a strict
reader on both sides ([scan worlds](../../../islands/scan/specs/worlds/README.md),
`islands/scan/scripts/record_world.py`). The gateway's equivalent records vendor answers inside the
running service (latest answer per source, `account` class reduced to structure) and cuts one JSON
path per fixture with a provenance sidecar. Taking scan's practice would mean: whole-answer worlds
instead of path cuts, a provenance lint (the open GW-WIRE-QUARRY gap), re-cutting the existing
hand-cut fixtures from recorded answers, and strict fake upstreams that fail an unrecorded read. The
gateway's fakes are in-process per test today; whether they refuse an unrecorded read was not checked.

## In flight

- R4: #3300 Goal (post-launch; production leg = `wire.json` on a codeowner path + `GATEWAY_WIRE`); #3328 bucket; #3304 recipe.
- R6: FU-270, FU-269 (no open issue found for either by title).
- R7: #3501, #3503, #3504 (blocked).
- R8: #3505 (blocked-on #3504).
- Island-only: #3305 Goal → PR #3590 (base `goal/3305-runtime-tiers`, armed, code reviewer APPROVED, specs reviewer CHANGES_REQUESTED, last update 2026-11-20); #3309, #3231, #3329; #3118 Goal (post-launch) → #3127; #3296, #3310, #3145, #3533, #3538, #3293, #2977, #2684, #2650.

## Next steps, in order

1. **R3/R2 cleanups** — label the 251 rows, fix the schema warnings. Nothing filed. Waits on nothing.
2. **R7** — #3501 and #3504, then #3503. Wait on #3088 (agent PRs touching `argocd/**`).
3. **R8** — #3505: first claim carried to a prod verdict. Waits on #3504.
4. **R4** — #3300 production leg (operator: `wire.json` is a codeowner path), then the provenance
   lint (not filed), then re-cut fixtures. Waits on the operator's declaration file.
5. **R6** — parity record and switch-over: FU-269 first (git broker, stateless, cheapest), then the
   coordinator/reviewer `/anthropic` base URL, then `/route` for other stacks. Nothing filed beyond
   FU-269/FU-270; the launch island's #3485 compares the gateway-admit replay family.

Real choice: R4 before R7/R8 or after. Recommendation: R7 first — it is blocked only on #3088, it
unblocks #3505, and the island's live risk is unmeasured rollouts (28 deploys in 7 days, per #3505),
not fixture provenance.

## What it can lend, what it should borrow

Lend, as is:
- the gate set: `gateway/scripts/spec_gate.py`, `spec-join-ratchet.py`, `spec-hygiene-ratchet.py`
  with their baselines (scan and retro already copy the shape);
- the site and evidence chain: `scripts/specs-build.sh`, `allure-report.sh`, `evidence-publish.sh`,
  `e2e-specs-site.sh`, `tests/test_specs_site_links.py` (`islands/scripts/specs-site.sh` already
  generalises the site);
- the in-service recorder and quarry: `src/agent_gateway/wire.py`, `scripts/wire-quarry.py` — for any
  island that reads a vendor or service over HTTP;
- the metrics/alert layout: one `*.promtool-rules` + `*.promtool-test` pair per alert family beside
  `prometheusrule.yaml`.

Borrow:
- from scan: whole-answer recorded worlds, `provenance.yaml`, strict readers (`islands/scan/specs/worlds/`);
- from oracle-fleet: the experiments file and release observation (#3505 names
  `gateway/experiments/experiments.json` and `release_observe.py` there); the dashboard-as-code shape.

## Three-group sort

| Item | Group | Why |
|---|---|---|
| R1, R2, R3, R5 | common | the spec process is the same pinned package everywhere |
| R4 worlds | common | every island and oracle mine worlds; the recorder kind differs (service-side vs gh/kubectl) |
| R6 replaces the old | platform-common | only rebuilt platform members have an old one |
| R7 metrics | common | Prometheus applies to any running service |
| R8 feedback loop | common | oracle has it; platform islands take it |
| R9, R10 | common | intake runs per island, stack islands by contract |
| spec cleanups | common | every island has unlabelled rows and gate warnings |
| parity with the old router | island-only | the old router is the gateway's alone |
| runtime tiers, Go headroom, codex catalog, Go sources | island-only | rail-specific |
| specs site, evidence to own storage | platform-common | homelab buckets and routes |
| wire capture of live traffic | island-only | for now |
| High Availability | stack-common | production services need it; platform islands are single-replica by design |

## Not verified

- Whether the deployed image (`2026.11.22-g2bea02fb2163`) serves `/wire` live and which sources it
  has recorded — no cluster query by brief.
- Whether gateway fake upstreams refuse an unrecorded read.
- The full `devbox run ci` (evidence, Allure report, site build, lychee) and `specs-site-e2e` — only
  the pytest suite and `spec_gate.py` were run.
- Whether any facts-file or rules change came from the wait ledger for this island specifically.
- The 4 rules in the spec gate (38) but not in the join baseline (34): not traced.
