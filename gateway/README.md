# agent-gateway — the LLM egress gateway island

The agent fleet's LLM egress gateway, rebuilt spec-first as an **island** inside the homelab
monorepo (ADR-139, P2 of `docs/spikes/context-and-autonomy.md`): its own build, specs, tests and
context, nothing shared with the old `argocd/resources/openrouter-proxy/`, which runs on
untouched in parallel until consumers move.

It owns three things: the **credential boundary** (a pod holds a `gws_…` session token, never a
real key), **per-session model resolution** (one model per session, from `policy.json`), and the
three live **rails** — `anthropic` (the operator's Claude subscription OAuth token), `openrouter`
(per-stack keys minted by openrouter-operator), `opencode` (the OpenCode Go key) — plus `codex`
(the ChatGPT subscription, `responses` dialect), which ships **dark**: no deployed policy declares
it and production ownership is wired only behind explicit environment settings.

## The contract

**The contract is `specs/`** — this README does not restate it.

| Topic | Where |
|---|---|
| Process rules, how rows are gated | [`specs/README.md`](specs/README.md) |
| Terms (session, rail, dialect, harness, credential ref, policy, defer, island) | [`specs/glossary.md`](specs/glossary.md) |
| The spine: launcher → pod env → LLM calls → release | [`specs/use-cases/uc-1-worker-ride.md`](specs/use-cases/uc-1-worker-ride.md) |
| `POST/GET/DELETE /sessions`, the bound pod's env pull `POST /sessions/{id}/env`, the judge's `GET /sessions?task=` (`GW-SESSIONS-*`, `GW-MODEL-RESOLVE`) | [`specs/endpoints/sessions.md`](specs/endpoints/sessions.md) |
| `POST /anthropic/v1/messages` (`GW-RAIL-*`, `GW-CRED-*`) | [`specs/endpoints/anthropic-messages.md`](specs/endpoints/anthropic-messages.md) |
| `POST /openai/v1/chat/completions`, `GET /openai/v1/models` — the OpenRouter rail and its provider axis (attribution, selection from the endpoint snapshot, request-level failover; `GW-RAIL-OPENROUTER`) | [`specs/endpoints/openai-chat.md`](specs/endpoints/openai-chat.md) |
| `POST /openai/v1/responses` — the dark codex rail (`GW-RAIL-CODEX`, `GW-CODEX-HEADROOM`, `GW-CODEX-OAUTH`) | [`specs/endpoints/openai-responses.md`](specs/endpoints/openai-responses.md) |
| `GET /catalog/opencode` — the Go catalog leg: vendor models, prices and per-model plan limits, refreshed every 6 h (`GW-CATALOG-GO`) | [`specs/endpoints/catalog.md`](specs/endpoints/catalog.md) |
| `GET /catalog/openrouter` — the OpenRouter catalog leg: the weekly ranking ∩ AA-benched, each candidate's endpoints, the cells' entry states, the floors' verdict per harness (`pinnable` / `floor`) and the budget-capped entry canary (`GW-CATALOG-OR`; the jail launcher `scripts/canary-entrants.sh` walks the pinnable candidate cells cheapest-first) | [`specs/endpoints/catalog.md#gw-catalog-or`](specs/endpoints/catalog.md#gw-catalog-or) |
| The tier evidence — the deployed policy's per-(rail, tier) model lists derived from benchmark evidence, ordered by cost per clean ride (the openrouter model's selected endpoint, the Go plan's discounted price), the committed snapshot and its staleness alert, the equality check; the admission's rail choice between a model's twin cells (`GW-MODEL-TIERS`; `devbox run tiers -- snapshot \| derive \| check \| apply`, `scripts/benchmarks-snapshot.sh`) | [`specs/endpoints/catalog.md#gw-model-tiers`](specs/endpoints/catalog.md#gw-model-tiers) |
| `GET /metrics` (`GW-METRICS`), `GET /healthz` (`GW-HEALTH`) | [`specs/endpoints/metrics.md`](specs/endpoints/metrics.md), [`specs/endpoints/health.md`](specs/endpoints/health.md) |
| Role × service access inventory (`GW-ACCESS`) | [`specs/access.md`](specs/access.md) |
| Fixture worlds (the test policy, fake upstream behaviours) | [`specs/worlds/`](specs/worlds/) |
| Evidence (rendered per requirement by `devbox run ci`; gitignored, read it in the CI job summary) | `specs/evidence/` |
| **The browsable site** — this README + `specs/` with the evidence fragments transcluded; master at the root, PR previews at `/pr-<N>/` (LAN/VPN; `mkdocs.yml`, `scripts/specs-publish.sh`, bucket `gateway-specs`) | [`gateway-specs.homelab.teststuff.net`](https://gateway-specs.homelab.teststuff.net) |

## Run

```sh
cd gateway
devbox run serve          # uvicorn on :8080; GATEWAY_POLICY=/etc/agent-gateway/policy.json, GATEWAY_DB=/data/gateway.db
```

Environment: `GATEWAY_POLICY`, `GATEWAY_DB` (`:memory:` fail-open if the file is unusable —
logged, and `/healthz` says `db: memory`), `OPENCODE_GO_API_KEY` (the gateway's own mounted Go
key), `GATEWAY_SELF_URL` (what the pod env points at; defaults to the cluster Service name),
`ANTHROPIC_UPSTREAM` / `OPENROUTER_UPSTREAM` / `OPENCODE_GO_UPSTREAM` (base URLs, overridable for
tests), `CODEX_UPSTREAM` (native backend; no default), `CODEX_SEED_FILE` (ESO-mounted JSON seed; SHA-256-gated import into `GATEWAY_DB`), `GATEWAY_CRED_CACHE_S` (300) / `GATEWAY_CRED_NEGATIVE_CACHE_S` (20),
`GATEWAY_GO_CATALOG_URL` / `GATEWAY_GO_CONFIG_URL` / `GATEWAY_GO_DOCS_URL` (the Go catalog's three
reads — models.dev, the console overlay, the Go page — overridable for tests) and `GATEWAY_GO_CATALOG_REFRESH_S` (21600; 0 = no schedule), `GATEWAY_OR_MCP_URL` (the OpenRouter
MCP the catalog's ranking + benchmark reads ride) and `GATEWAY_OR_CATALOG_REFRESH_S` (21600; 0 = no schedule),
`GATEWAY_BENCHMARKS` (the committed tier-evidence snapshot mounted beside the policy; its age is a gauge).

Deploy manifests: `argocd/resources/agent-gateway/` (the Service is
`agent-gateway.agent-egress.svc.cluster.local:8080`); image built by
`.github/workflows/gateway-image.yaml`.

## Test

```sh
cd gateway
devbox run ci             # THE gate: uv sync --frozen, ruff, pytest (+ evidence), spec gate, evidence render
devbox run test -- -k admit   # one table
devbox run evidence       # after a test run: allure-results/ → allure-evidence/ (evidence.json, digest.md, <RULE>.md, allure-results/)
```

Every test module is a decision table (`@pytest.mark.parametrize(..., ids=[row descriptions])`
with the same table in the module docstring) under one `@rule("GW-…")` marker, which fails at
collection when `specs/` has no such heading. The plugin in `tests/conftest.py` writes
`evidence/evidence.json`; `scripts/spec_gate.py` couples requirement headings ⇄ schema
`x-requirements` ⇄ evidence rows; `scripts/evidence_render.py` renders the per-rule tables.
Every run also writes raw **Allure** results (`allure-results/`, pyproject `addopts`) in the
oracle-fleet conventions' shape (ADR-156 — one portable process): `rule()` sets story == rule ID
(epic = spec page, feature = section, a link to the anchor), every case names its world
(`world()` → the `world` label; a rule-labelled case without one fails), and its steps read
`Given:` / one `When:` / `Then:` per claim (a `verdict: …` JSON with expected/actual under each),
with every gateway and fake-upstream exchange attached under the step it supports;
`environment.properties` stamps `git.commit` (the head sha — the pinned snippets key), policy sha256, timestamp and
`artifact=pr-head (not the built image)`. `devbox run evidence` (`scripts/gateway-evidence.sh`,
snippets pin in `scripts/lib/snippets.sh`) turns them into the reviewer's pack, joining each spec
page's tables (`--spec`) where the tool can parse them; `evidence_render.py` and its
`evidence-render: BEGIN/END` log block are unchanged.
`GATEWAY_SPECS_OPTIONAL=1` lets the rule check + gate skip with a warning when `specs/` is absent
(only for a checkout that carries the service half alone — CI never sets it).

The test policy `tests/fixtures/policy-default.json` must stay **byte-identical** to
`specs/worlds/policy-default.json` (the gate checks it when both exist). Model ids live only in
policy files — never in code (`GW-MODEL-RESOLVE`): the policy carries `model-classes.json`'s
spelling (`claude/<alias>`, `opencode-go/<id>`, bare openrouter ids) and the gateway derives
the wire id by stripping the rail prefix. The deployed policy
(`argocd/resources/agent-gateway/policy.json`, generated into the `agent-gateway-policy`
ConfigMap by a hash-suffixed configMapGenerator, so an edit rolls the pod) carries the same shape; a
`GW-MODEL-RESOLVE` row loads it through the same loader and checks its ids against
`model-classes.json`. Its three rails' tier LISTS are not hand-picked: `GW-MODEL-TIERS` derives them
from `argocd/resources/agent-gateway/benchmarks.json` (the committed tier evidence) under the
policy's `tiers` block, and a row fails the suite when a list drifts from the derivation.

## Implementation notes the specs do not state

- The OpenAI dialect is served under `/openai/v1/*` (the contract) **and** `/api/v1/*` (the
  OpenRouter-shaped alias): goose computes `$OPENROUTER_HOST/api/v1/…` and opencode's provider
  baseURL is `<host>/api/v1` today (`agents/agent-session.sh`), so the alias is what those
  harnesses reach if a launcher keeps today's wiring. One handler set, two prefixes.
- The codex rail uses gateway-local SQLite in `GATEWAY_DB`; `CODEX_UPSTREAM` and
  `CODEX_SEED_FILE` enable the executable's native backend. The mounted seed is imported only
  when its content hash changes; rotations and recovery markers remain local and durable.
  The deployed policy still omits Codex. Native-CLI evidence lives in `experiments/codex-rail/`.
- The `upstream-slow` world is clock-faked (the fake transport raises `ReadTimeout`), so the
  `upstream-timeout` rows prove the 504 mapping, not the 600 s budget itself (specs: `🚧 WIP`).
