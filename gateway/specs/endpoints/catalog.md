---
id: EP-CATALOG
use-cases: [UC-1]
schema: catalog.schema.json
---
# GET /catalog/opencode — the Go rail's vendor facts, read from the vendor

*Which [Go rail](../../../docs/agents/chainless-redesign.md) models exist, what they cost, and how
much of each the plan allows* — the [Go catalog](../glossary.md#go-catalog). Until this leg,
those facts were copied by hand into `policy.json` and `gometer.py`, and the copy went stale:
the gateway's only Go model left the Go catalog on 2026-10-14 and nothing noticed
([opencode-go-catalog.md](../../../docs/spikes/opencode-go-catalog.md) §F3). The gateway now
reads them on a schedule from two vendor sources, keeps the last good snapshot of each in its
store, and shows both here and on `/metrics`. This page owns only the reading; admission does
not read the snapshot yet (the `⚑ gap` row below — [GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit) still prices from the policy). The
design input and the operator's rulings are the spike's §Rulings.

## Interface — the machine half

**[`catalog.schema.json`](catalog.schema.json)** holds the view's shape (`output`) and the two
normalised snapshots (`$defs.config_snapshot`, `$defs.docs_snapshot`) the store keeps. The
`gateway_go_catalog_*` families are declared in [metrics.schema.json](metrics.schema.json) with
the other families. No error codes: the view answers 200 (no snapshot = empty rows, never an
error), and no auth, like `/metrics` — it carries no credential.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-CATALOG-GO](#gw-catalog-go) | `output`, `$defs.config_snapshot`, `$defs.docs_snapshot`, metrics `families.gateway_go_catalog_*` | — | v0 — the read leg. Admission reading it is `⚑ gap` ([GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit)'s, next); models.dev as a fallback source and a liveness signal are `⚑ gap` (rows below) |

## GW-CATALOG-GO

Two **sources**, each refreshed every **21600 s** ⚖ (6 h; the first refresh runs at start) and
each with its own snapshot:

- **`config`** — `GET https://opencode.ai/console/api/v2/config`, the console's V2 config, which
  any Go key can read. The leg keeps `providers["opencode-go"].models`: per model the `family`,
  tool support, `limit.context` / `limit.output`, and `cost[]` (the base row, then each
  `tier: {type: context, size}` row as the rate above that many tokens). A row marked
  `"disabled": true` is not listed. The request carries the Go key as a bearer, a `User-Agent`
  and a fresh `x-opencode-session` — Cloudflare answers 1010 to a bare client.
- **`docs`** — the vendor's Go page source, `go.mdx` on the vendor repo's default branch
  (`raw.githubusercontent.com/anomalyco/opencode/dev/services/www/src/docs/content/console/go.mdx`),
  fetched with no credential. The leg reads each model's **monthly limit** under each plan tab
  (`go`, `go-plus`), a promotion's multiplier, the `(Peak)` price rows, the peak-hours sentence and
  the 5-hour / weekly / monthly share of the monthly limit. Rows are keyed by **model id** through
  the page's own Endpoints table (display name → Model ID). ⚖ `go-models.ts` (the spike's second
  file) is not read: it keys rows by family (`deepseek-flash`), and limits are per model (ruling 3);
  `go.mdx` carries every fact the leg needs.

The parse is **strict**: a shape the parser does not know is a parse failure, never a guess —
whatever the parser raises on it is counted `parse-failed`, and one source's failure never skips
the other source's refresh. A
refresh whose fetch fails, whose parse fails, or whose model count drops below **half** ⚖ of the
last good snapshot's (zero models always) keeps the last good snapshot. The snapshot is written
to the gateway's store (`catalog_snapshots`, one row per source), so a restarted gateway starts
from it. The policy names the plan (`rails.opencode.plan`: `go` | `go-plus`, required) because no
vendor API says which plan a key is on (ruling 4).

Rows run at T0 = 2027-01-15T08:00:00Z against the `policy-default` world and the fake vendor
([worlds/README.md §The Go catalog's fakes](../worlds/README.md#the-go-catalogs-fakes)): `catalog-ok`
serves `tests/fixtures/go-catalog/config.json` (five listed models, one disabled row), `docs-ok`
serves `tests/fixtures/go-catalog/go.mdx` (the same five models). Both are trimmed from the live
answers of 2026-10-17.

### What a refresh keeps

| description | last good (config) | the fake answers || outcome | snapshot | models |
|---|---|---||---|---|---|
| "a first good fetch becomes the snapshot" | none | `catalog-ok` || ok | the new one, `fetched_at` T0 | 5 |
| "a disabled row is not listed" | none | `catalog-ok` (6 rows, `deepseek-v4-flash` disabled) || ok | `deepseek-v4-flash` absent | 5 |
| "a later good fetch replaces it" | 5, fetched T0 | `catalog-ok` at T0 + 21600 s || ok | `fetched_at` T0 + 21600 s | 5 |
| "an upstream error keeps the last good" | 5, fetched T0 | `catalog-503` || fetch-failed | the last good, `fetched_at` T0 | 5 |
| "an unreachable vendor keeps the last good" | 5, fetched T0 | `catalog-down` || fetch-failed | the last good | 5 |
| "a row without its cost is a parse failure" | 5, fetched T0 | `catalog-malformed` (`deepseek-v4-pro` has no `cost`) || parse-failed | the last good | 5 |
| "a body without the Go provider is a parse failure" | 5, fetched T0 | `catalog-no-provider` || parse-failed | the last good | 5 |
| "a drop below half the models is implausible ⚖" | 5, fetched T0 | `catalog-shrunk` (2 listed) || implausible | the last good | 5 |
| "a drop to half or more is taken ⚖" | 5, fetched T0 | `catalog-trimmed` (3 listed) || ok | the new one | 3 |
| "zero models is implausible with no last good" | none | `catalog-empty` || implausible | none | 0 |

The `docs` source keeps its snapshot by the same rules; its model count is the number of model
ids with a row in either plan tab.

| description | last good (docs) | the fake answers || outcome | snapshot |
|---|---|---||---|---|
| "the page parses" | none | `docs-ok` || ok | 5 models |
| "a 404 keeps the last good — the page moved" | 5 | `docs-404` || fetch-failed | the last good |
| "a plan row naming a model the Endpoints table lacks is a parse failure" | 5 | `docs-unknown-model` (a `DeepSeek V4.2 Flash` row) || parse-failed | the last good |
| "an Endpoints row with one cell is a parse failure" | 5 | `docs-short-endpoint-row` (`\| Step 5 Preview \|`) || parse-failed | the last good |
| "a renamed limit column is a parse failure" | 5 | `docs-header-drift` (`Monthly limit` → `Limit`) || parse-failed | the last good |
| "peak rows without the peak-hours sentence are a parse failure" | 5 | `docs-no-peak-hours` || parse-failed | the last good |
| "no share sentence is a parse failure" | 5 | `docs-no-shares` || parse-failed | the last good |
| "a drop below half the models is implausible" | 5 | `docs-shrunk` (2 models) || implausible | the last good |

### What the page says, per model

`docs-ok`, read through `GET /catalog/opencode` (plan `go` — the `policy-default` world) and the
docs snapshot (both plans):

| description | model || plan go | plan go-plus | bonus | peak row (in / out / cache_read / cache_write) |
|---|---||---|---|---|---|
| "a plain row gives the monthly limit per plan" | `deepseek-v4.1-flash` || $80 | $160 | — | 0.30 / 1.20 / 0.006 / `null` |
| "a promotion reads the current limit, not the struck one" | `step-5-preview` || $60 | $240 | 4 | — |
| "Unlimited is unlimited" | `longcat-2.5-preview-free` || `unlimited` | `unlimited` | — | — |
| "context-tier rows are one model with one limit" | `claude-haiku-5-5` || $15 | $60 | — | — |

| description | input || the snapshot reads |
|---|---||---|
| "the peak hours come from the page" | `docs-ok`'s *"Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday through Friday"* || `peak_hours_utc` `[[1, 4], [6, 10]]`, `peak_weekdays` mon–fri |
| "the window shares come from the page" | *"5-hour — 20% of the monthly limit; weekly — 50%; and monthly — 100%"* || `window_shares` 5h 0.2 · 7d 0.5 · 30d 1.0; `deepseek-v4.1-flash` `windows_usd` 16 / 40 / 80 |
| "the config's prices are the model's cost rows" | `catalog-ok`'s `claude-haiku-5-5` || `cost` base 0.10 / 0.50 / 0.01 / 0.125, above 100000 tokens 0.50 / 2.50 / 0.05 / 0.625 |
| "a model the page tabulates but the config does not list is shown unlisted" | `catalog-trimmed` (no `step-5-preview`) + `docs-ok` || `step-5-preview` `listed: false`, `monthly_limit_usd` 60 |
| "the view's shape is the schema's" | `catalog-ok` + `docs-ok`, `GET /catalog/opencode` || exactly the `required` keys of `output`, of a model row and of a source state |

### The plan

| description | `rails.<rail>.plan` in an otherwise `policy-default` document || the policy load |
|---|---||---|
| "the declared plan picks the limits' tab" | opencode `go` || loads; the view's `plan` is `go` |
| "no plan refuses the load" | opencode absent || refused, naming `rails.opencode.plan` |
| "an unknown plan refuses the load" | opencode `pro` || refused, naming `rails.opencode.plan` |
| "a plan on another rail refuses the load" | openrouter `go` || refused, naming `rails.openrouter.plan` |

### What a fetch sends

| description | source || `authorization` | `user-agent` | `x-opencode-session` |
|---|---||---|---|---|
| "the config fetch carries the key and a client identity" | config || `Bearer <the Go key>` | `agent-gateway/<version> (go-catalog)` | a UUID, new on every fetch |
| "the docs fetch carries no credential" | docs || absent | `agent-gateway/<version> (go-catalog)` | absent |
| "no key, no config fetch" | config, `OPENCODE_GO_API_KEY` unset || — (no request is sent; outcome fetch-failed) | — | — |
| "the key never reaches a log line" | config answering 401 with the key in its body || — (every `gateway.catalog` line is free of the key) | — | — |

### Kept across a restart

| description | sequence || after the restart, before any refresh |
|---|---||---|
| "a PVC store keeps the snapshot" | `catalog-ok` + `docs-ok`, then a new gateway on the same DB, clock + 3600 s || both snapshots served; `age_s` 3600; `gateway_go_catalog_models{source="config"}` 5 |
| "a corrupt stored snapshot is ignored" | a stored config row that is not JSON || no config snapshot; the next refresh replaces it |

### What `/metrics` says

| description | event || series | value |
|---|---||---|---|
| "age is seconds since the last good fetch" | `catalog-ok` at T0, read at T0 + 600 s || `gateway_go_catalog_age_seconds{source="config"}` | 600 |
| "no snapshot, no age" | nothing fetched || `gateway_go_catalog_age_seconds{source="config"}` | absent |
| "the model count of the last good snapshot" | `catalog-ok`, then `catalog-shrunk` || `gateway_go_catalog_models{source="config"}` | 5 |
| "every refresh is counted by outcome" | `catalog-ok`, then `catalog-malformed` || `gateway_go_catalog_refresh_total{source="config",outcome="ok"}` / `"parse-failed"` | 1 / 1 |
| "the last outcome is 1, the others 0" | `catalog-ok`, then `catalog-malformed` || `gateway_go_catalog_last_outcome{source="config",outcome="parse-failed"}` / `"ok"` | 1 / 0 |
| "policy Go models the config does not list are counted" | `catalog-ok`; `policy-default` names `deepseek-v4-flash` and `claude-sonnet-4-6` || `gateway_go_catalog_policy_models_missing{source="config"}` | 2 |
| "policy Go models without a limit row under the plan are counted" | `docs-ok`, the same two ids || `gateway_go_catalog_policy_models_missing{source="docs"}` | 2 |

No family carries a `model` label ([GW-METRICS](metrics.md#gw-metrics)): the missing ids are
named in the refresh's log line and in the view's `policy_models`. The alert rules on these
families — `GoCatalogStale` (a source's last good snapshot older than 24 h ⚖, or none),
`GoCatalogParseFailed` (the last refresh parse-failed or was implausible) and
`GoCatalogPolicyModelMissing` (a policy Go model uncovered) — live in
`argocd/resources/agent-gateway/prometheusrule.yaml`, with their promtool fixture
`go-catalog.promtool-test` beside it.

### Named gaps (rows that exist so the omission is visible)

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: admission reads the snapshot" | a Go admission || priced from `policy.json` `window_draw` (the hand copy) | the second half of this leg: the window draw prices from the snapshot, sizes each model's windows from its own monthly limit, and refuses an unlisted id `not-in-catalog` (the spike's rulings 3–5) |
| "⚑ gap: models.dev as a fallback" | the console config unreachable for a day || the last good snapshot, `GoCatalogStale` | the spike's §F4: `models.dev/api.json` mirrors the vendor and carries the only machine-readable `deprecated` marker |
| "⚑ gap: listed is not alive" | a listed id that answers 400 `Model is unavailable` || listed | the spike's §F3 / gap 4: no vendor source is a liveness signal; the shadow cells and the 4xx/5xx belts are |
| "⚑ gap: a vendor reset time" | a Go 429 || — (this leg reads no usage) | the spike's gap 6: no real Go 429 has been observed |
| "⚑ gap: the OpenRouter rail's registry" | an openrouter session || no catalog | the old proxy reads `/api/v1/models/<id>/endpoints` for its provider pin and price (`compute_pin`, `MARKET_TTL_S`); the gateway's openrouter rail forwards the policy model with no registry (the spike's §Proposed design) |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CATALOG-GO.md"

</details>
