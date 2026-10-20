---
id: EP-CATALOG
use-cases: [UC-1]
schema: catalog.schema.json
---
# GET /catalog/opencode · GET /catalog/openrouter — the two rails' vendor facts, read from the vendor

*Which [Go rail](../../../docs/agents/chainless-redesign.md) models exist, what they cost, and how
much of each the plan allows* — the [Go catalog](../glossary.md#go-catalog). Until this leg,
those facts were copied by hand into `policy.json` and `gometer.py`, and the copy went stale:
the gateway's only Go model left the Go catalog on 2026-10-14 and nothing noticed
([opencode-go-catalog.md](../../../docs/spikes/opencode-go-catalog.md) §F3). The gateway now
reads them on a schedule from two vendor sources, keeps the last good snapshot of each in its
store, and shows both here and on `/metrics`. Admission reads the snapshot — the Go window
draw's prices, each model's own windows, `not-in-catalog`
([GW-SESSIONS-ADMIT §Capacity](sessions.md#capacity--the-ladders-capacity-half)); this page owns only the reading. The
design input and the operator's rulings are the spike's §Rulings.

This page is *what the gateway knows about models and where it comes from*, so it carries two
more rules: [GW-CATALOG-OR](#gw-catalog-or) — the openrouter rail's registry, the
[endpoint snapshot](../glossary.md#endpoint-snapshot) GW-RAIL-OPENROUTER selects from, with its
budget-capped **entry canary** (operator rulings 2026-10-19, homelab#2742) — and
[GW-MODEL-TIERS](#gw-model-tiers) — the deployed policy's per-(rail, tier) model
lists are **derived from benchmark evidence** ([tier evidence](../glossary.md#tier-evidence)),
never hand-picked.

## Interface — the machine half

**[`catalog.schema.json`](catalog.schema.json)** holds the view's shape (`output`), the two
normalised snapshots (`$defs.config_snapshot`, `$defs.docs_snapshot`) the store keeps, the
tier-evidence snapshot (`$defs.benchmarks_snapshot`) and the policy's `tiers` block (`$defs.tiers_block`). The
`gateway_go_catalog_*` families are declared in [metrics.schema.json](metrics.schema.json) with
the other families. No error codes: the view answers 200 (no snapshot = empty rows, never an
error), and no auth, like `/metrics` — it carries no credential.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-CATALOG-GO](#gw-catalog-go) | `output`, `$defs.config_snapshot`, `$defs.docs_snapshot`, metrics `families.gateway_go_catalog_*` | — | v0 — the read leg; admission reads it ([GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit) §Capacity owns those rows); since 2026-10-20 the `config` source is models.dev's catalog under the console's overlay (the console answer became override-only that day); a liveness signal is `⚑ gap` (rows below); `⚑ gap (2026-10-20, PR #2766 → work #2768)`: rail-served ids the catalog does not list (`/zen/go/v1/models` is unread) |
| [GW-CATALOG-OR](#gw-catalog-or) | `openrouter_output`, `$defs.openrouter_snapshot`, `$defs.catalog_block`, `$defs.canary_block`, `$defs.cell_state`; sessions.schema.json `post.input.canary` + the defer reasons `canary-budget`, `canary-not-due`; metrics `families.gateway_openrouter_catalog_*`, `gateway_openrouter_cells`, `gateway_canary_*` | — (`not-in-catalog` / `canary-not-due` / `canary-budget` are defers, never HTTP errors) | v0 — the registry (ranking ∩ benched → endpoints per candidate, the persisted snapshot, the view, the families, the stale alert), the entry canary and its cap; the canary RIDE's launcher is the jail's `gateway/scripts/canary-entrants.sh` (`⚑ gap` rows below: no in-cluster trigger, the Go rail's canary); ⚑ gap (2026-10-20, PR #TBD → work #2775): a 429'd canary spends an admission and judges nothing, a pod roll resets the per-refresh cap, the view does not say which cells selection could pin |
| [GW-MODEL-TIERS](#gw-model-tiers) | `$defs.benchmarks_snapshot` (the committed `argocd/resources/agent-gateway/benchmarks.json`), `$defs.tiers_block` (the policy's `tiers`, incl. `cost`), `$defs.price_basis`, `$defs.rides`; `output.pricing` (the Go price on `GET /catalog/opencode`); sessions.schema.json `$defs.rail_choice` (the dispatch answer's `rail_choice`); metrics `families.gateway_rail_choice_total`, `gateway_tier_evidence_age_seconds` | — (the loader refuses a malformed `tiers` block; `tiers check` exits 1 on a drifted list) | v0 — the derivation by COST PER CLEAN RIDE (the openrouter model's selected endpoint, the Go plan's discounted price, the cell's clean-ride rate), the committed snapshot and its staleness alert, the equality check with undecided tiers, the admission's rail choice between twin cells (homelab#2743); `⚑ gap (2026-10-18, PR #2716 → work #2718)`: no price for the subscription rail (score ascending is the proxy), the coding/agentic axes unused, Go-only id spellings unbenched; `⚑ gap (2026-10-20, homelab#2743)`: the Go rail's quantization undeclared, the strike overhead unmeasured, the Go cell's clean-rate prior (the "⚑ gap" rows below) |

## GW-CATALOG-GO

Two **sources**, each refreshed every **21600 s** ⚖ (6 h; the first refresh runs at start) and
each with its own snapshot:

- **`config`** — two reads, merged the way the vendor's own client merges them
  (`packages/core/src/plugin/provider/opencode.ts`; ⚖ 2026-10-20). The **catalog read**:
  `https://models.dev/api.json`, the vendor's own public registry (the spike's §F4) — the leg
  keeps its `opencode-go.models`: per model the `name`, `family`, `tool_call`, `limit.context` /
  `limit.output`, and `cost` (`input` / `output` / `cache_read` / `cache_write`, then each
  `tiers[]` row with its `tier: {type: context, size}` as the rate above that many tokens; the
  legacy `context_over_200k` spelling is not read, and alone it is a shape the parser does not
  know). A row whose `status` is `deprecated` is not listed — the vendor's loader
  (`plugin/models-dev.ts`) drops it before any overlay. Then the **console read**:
  `GET https://opencode.ai/console/api/v2/config`, the console's V2 config, which any Go key can
  read — since 2026-10-20 it carries the WORKSPACE'S OVERRIDES on that catalog, not the catalog
  (`providers["opencode-go"].models` is `{}` for this account; until that day it carried every
  row, which the 10-17 build read as the catalog): `"disabled": true` unlists the row; a `cost`
  (the vendor's list-or-one-row spelling), a `limit` field, a `name`, `family` or
  `capabilities.tools` present on a row wins over the catalog's; an override naming no catalog
  row is listed only when it is a complete row of its own (a cost and both limits). The console
  request carries the Go key as a bearer, a `User-Agent` and a fresh `x-opencode-session` —
  Cloudflare answers 1010 to a bare client; the catalog read carries no credential. The two reads
  are one source: the first that fails ends the refresh with its outcome (the log line names the
  read), and the merged listing is the one snapshot admission reads.
- **`docs`** — the vendor's Go page source, `go.mdx` on the vendor repo's default branch
  (`raw.githubusercontent.com/anomalyco/opencode/dev/services/www/src/docs/content/console/go.mdx`),
  fetched with no credential. The leg reads each plan's **monthly fee** (the page's Plan table —
  `| **Go** | **$10/month** |`; the [Go price](../glossary.md#go-price) divides the policy plan's),
  each model's **monthly limit** under each plan tab (`go`, `go-plus`), a promotion's multiplier,
  the `(Peak)` price rows, the peak-hours sentence and the 5-hour / weekly / monthly share of the
  monthly limit. Rows are keyed by **model id** through the page's own Endpoints table (display
  name → Model ID); the fees by the Plan table's plan names. ⚖ `go-models.ts` (the spike's second
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
serves `tests/fixtures/go-catalog/models-dev.json` (models.dev's `opencode-go`: five listed models
and one `status: deprecated` row), `config-ok` serves `tests/fixtures/go-catalog/config.json` (the
console's override-only answer, `opencode-go.models: {}`), `docs-ok` serves
`tests/fixtures/go-catalog/go.mdx` (the same five models). The first two are trimmed from the live
answers of 2026-10-20, the page from 2026-10-17/20. The `catalog-*` knobs vary the models.dev
read, the `config-*` knobs the console read; a refresh of the `config` source makes both.

### What a refresh keeps

| description | last good (config) | the fake answers || outcome | snapshot | models |
|---|---|---||---|---|---|
| "a first good fetch becomes the snapshot" | none | `catalog-ok` + `config-ok` || ok | the new one, `fetched_at` T0 | 5 |
| "a deprecated catalog row is not listed" | none | `catalog-ok` (6 rows, `step-5-preview-free` `status: deprecated`) || ok | `step-5-preview-free` absent | 5 |
| "an override-only console answer lists the catalog as is ⚖" | none | `config-ok` (`opencode-go.models: {}` — the live answer) || ok | the catalog's five | 5 |
| "a disabled override unlists the row" | 5, fetched T0 | `config-disables` (`deepseek-v4-pro: {disabled: true}`) || ok | `deepseek-v4-pro` absent | 4 |
| "a cost or limit override wins" | 5, fetched T0 | `config-reprices` (`claude-haiku-5-5`: two `cost` rows, `limit.context` 200000) || ok | its `cost` the override's two rows; `context` 200000, `output` the catalog's 128000 | 5 |
| "a console-only row with a cost and both limits is listed ⚖" | 5, fetched T0 | `config-adds` (`deepseek-v4-flash`, no catalog row) || ok | `deepseek-v4-flash` listed with the override's cost, limits, family, tools | 6 |
| "a console-only row without them lists nothing ⚖" | 5, fetched T0 | `config-adds-bare` (`deepseek-v4-flash: {disabled: false}`) || ok | `deepseek-v4-flash` absent | 5 |
| "a later good fetch replaces it" | 5, fetched T0 | `catalog-ok` + `config-ok` at T0 + 21600 s || ok | `fetched_at` T0 + 21600 s | 5 |
| "an upstream error on the catalog read keeps the last good" | 5, fetched T0 | `catalog-503` || fetch-failed | the last good, `fetched_at` T0 | 5 |
| "an upstream error on the console read keeps the last good" | 5, fetched T0 | `config-503` || fetch-failed | the last good | 5 |
| "an unreachable catalog host keeps the last good" | 5, fetched T0 | `catalog-down` || fetch-failed | the last good | 5 |
| "an unreachable console keeps the last good" | 5, fetched T0 | `config-down` || fetch-failed | the last good | 5 |
| "a catalog row without its cost is a parse failure" | 5, fetched T0 | `catalog-malformed` (`deepseek-v4-pro` has no `cost`) || parse-failed | the last good | 5 |
| "a legacy context_over_200k row with no tiers is a parse failure ⚖" | 5, fetched T0 | `catalog-legacy-tier` || parse-failed | the last good | 5 |
| "an override whose cost is not a cost is a parse failure" | 5, fetched T0 | `config-malformed` (`deepseek-v4-pro: {cost: "free"}`) || parse-failed | the last good | 5 |
| "a catalog without the Go provider is a parse failure" | 5, fetched T0 | `catalog-no-provider` || parse-failed | the last good | 5 |
| "a console answer without the Go provider is a parse failure" | 5, fetched T0 | `config-no-provider` || parse-failed | the last good | 5 |
| "a drop below half the models is implausible ⚖" | 5, fetched T0 | `catalog-shrunk` (2 listed) || implausible | the last good | 5 |
| "a drop to half or more is taken ⚖" | 5, fetched T0 | `catalog-trimmed` (3 listed) || ok | the new one | 3 |
| "zero models is implausible with no last good" | none | `catalog-empty` || implausible | none | 0 |

The `docs` source keeps its snapshot by the same rules; its model count is the number of model
ids with a row in either plan tab. The `config` source's model count is the merged listing's.

| description | last good (docs) | the fake answers || outcome | snapshot |
|---|---|---||---|---|
| "the page parses" | none | `docs-ok` || ok | 5 models |
| "a 404 keeps the last good — the page moved" | 5 | `docs-404` || fetch-failed | the last good |
| "a plan row naming a model the Endpoints table lacks is a parse failure" | 5 | `docs-unknown-model` (a `DeepSeek V4.2 Flash` row) || parse-failed | the last good |
| "an Endpoints row with one cell is a parse failure" | 5 | `docs-short-endpoint-row` (`\| Step 5 Preview \|`) || parse-failed | the last good |
| "a renamed limit column is a parse failure" | 5 | `docs-header-drift` (`Monthly limit` → `Limit`) || parse-failed | the last good |
| "peak rows without the peak-hours sentence are a parse failure" | 5 | `docs-no-peak-hours` || parse-failed | the last good |
| "no share sentence is a parse failure ⚖" | 5 | `docs-no-shares` || parse-failed | the last good |
| "no plan table is a parse failure ⚖" | 5 | `docs-no-plan-table` || parse-failed | the last good |
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
| "the plan fees come from the page ⚖" | `docs-ok`'s Plan table *"\| **Go** \| **$10/month** \|"* / *"\| **Go Plus** \| **$40/month** \|"* || `plan_fee_usd_month` 10 (plan `go`); the docs snapshot's `plan_fees` go 10 / go-plus 40 |
| "the peak hours come from the page ⚖" | `docs-ok`'s *"Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday through Friday"* || `peak_hours_utc` `[[1, 4], [6, 10]]`, `peak_weekdays` mon–fri |
| "the window shares come from the page ⚖" | *"5-hour — 20% of the monthly limit; weekly — 50%; and monthly — 100%"* || `window_shares` 5h 0.2 · 7d 0.5 · 30d 1.0; `deepseek-v4.1-flash` `windows_usd` 16 / 40 / 80 |
| "the config's prices are the model's cost rows" | `catalog-ok`'s `claude-haiku-5-5` (models.dev's `cost` + its `tiers[0]`) || `cost` base 0.10 / 0.50 / 0.01 / 0.125, above 100000 tokens 0.50 / 2.50 / 0.05 / 0.625 |
| "a model the page tabulates but the config does not list is shown unlisted" | `catalog-trimmed` (no `step-5-preview`) + `docs-ok` || `step-5-preview` `listed: false`, `monthly_limit_usd` 60 |
| "the view's shape is the schema's" | `catalog-ok` + `docs-ok`, `GET /catalog/opencode` || exactly the `required` keys of `output`, of a model row and of a source state |

### The plan

| description | `rails.<rail>.plan` in an otherwise `policy-default` document || the policy load |
|---|---||---|
| "the declared plan picks the limits' tab" | opencode `go` || loads; the view's `plan` is `go` |
| "no plan refuses the load" | opencode absent || refused, naming `rails.opencode.plan` |
| "an unknown plan refuses the load" | opencode `pro` || refused, naming `rails.opencode.plan` |
| "a plan on another rail refuses the load" | openrouter `go` || refused, naming `rails.openrouter.plan` |

What the policy no longer holds (ruling 5): the vendor facts live in the snapshot, so a policy that
still carries one refuses to load — a stale hand copy can never shadow the catalog.

| description | `rails.opencode.admission` in an otherwise `policy-default` document || the policy load |
|---|---||---|
| "a price row in the policy refuses the load" | `window_draw.prices` = the old `deepseek-v4.1-flash` row || refused, naming `prices` |
| "a fallback price refuses the load" | `window_draw.fallback` = 9.00 / 9.00 || refused, naming `fallback` |
| "a window budget refuses the load" | `window_draw.windows.5h.budget_usd` = 12 || refused, naming `budget_usd` |
| "a window the vendor gives no share refuses the load" | `window_draw.windows.1d` || refused, naming `windows.1d` |
| "an unknown latch scope refuses the load" | `latch_scope: rail` || refused, naming `latch_scope` |

The same rule holds a Go model's harness window: the dispatch answer's `context_tokens` is the
snapshot's `context`, and a policy `context_tokens` entry for an `opencode-go/*` model refuses the
load — the rows live on [GW-SESSIONS-ENV](sessions.md#gw-sessions-env).

### What a fetch sends

| description | read || `authorization` | `user-agent` | `x-opencode-session` |
|---|---||---|---|---|
| "the console read carries the key and a client identity" | config (the console) || `Bearer <the Go key>` | `agent-gateway/<version> (go-catalog)` | a UUID, new on every fetch |
| "the catalog read carries no credential" | catalog (models.dev) || absent | `agent-gateway/<version> (go-catalog)` | absent |
| "the docs fetch carries no credential" | docs || absent | `agent-gateway/<version> (go-catalog)` | absent |
| "no key, no config fetch" | config, `OPENCODE_GO_API_KEY` unset || — (no request is sent on either read; outcome fetch-failed) | — | — |
| "the key never reaches a log line" | the console answering 401 with the key in its body (`config-401-echo`) || — (every `gateway.catalog` line is free of the key) | — | — |

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
| "every policy Go model listed: none missing" | `catalog-ok`; `policy-default` names `deepseek-v4.1-flash` and `claude-haiku-5-5` || `gateway_go_catalog_policy_models_missing{source="config"}` | 0 |
| "policy Go models the config does not list are counted" | `catalog-shrunk` (no `claude-haiku-5-5`) || `gateway_go_catalog_policy_models_missing{source="config"}` | 1 |
| "policy Go models without a limit row under the plan are counted" | `docs-shrunk` (no `claude-haiku-5-5` row) || `gateway_go_catalog_policy_models_missing{source="docs"}` | 1 |

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
| "⚑ gap: a rail-served id the catalog does not list" | `/zen/go/v1/models` naming an id models.dev lacks (37 served against 29 listed, 2026-10-20) || not-in-catalog (ruling 4) | [#2768](https://github.com/teststuffstash/homelab/issues/2768): *listed* is the vendor's client view (models.dev minus deprecated, under the workspace's overrides), never the rail's model list — the rail's own `/models` answer is unread, and no price comes with it |
| "⚑ gap: listed is not alive" | a listed id that answers 400 `Model is unavailable` || listed | the spike's §F3 / gap 4: no vendor source is a liveness signal; the shadow cells and the 4xx/5xx belts are |
| "⚑ gap: a vendor reset time" | a Go 429 || — (this leg reads no usage) | the spike's gap 6: no real Go 429 has been observed |
| "⚑ gap: the OpenRouter rail's registry" | an openrouter session || no catalog | the old proxy reads `/api/v1/models/<id>/endpoints` for its provider pin and price (`compute_pin`, `MARKET_TTL_S`); the gateway's openrouter rail forwards the policy model with no registry (the spike's §Proposed design) |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CATALOG-GO.md"

</details>

## GW-CATALOG-OR

*The openrouter rail's registry is read from the vendor, and a provider enters the order only
after a clean canary through our stack* (operator rulings 2026-10-19: the candidate set is never
a hand table; vendor numbers alone do not whitelist — laguna read 100 % up while we saw 81 % 429s;
the canary is ON DEMAND, part of this catalog's update, and CAPPED by a budget). The leg mirrors
[GW-CATALOG-GO](#gw-catalog-go): read on a schedule (⚖ `GATEWAY_OR_CATALOG_REFRESH_S`, 21600 s —
6 h, the Go catalog's interval; the first refresh at start), parsed strictly, the last good
snapshot kept on any failure and persisted in the store, shown on `/metrics` and on
`GET /catalog/openrouter`. What it reads:

- **The ranked set** — the vendor's weekly ranking, the MCP `list-daily-model-rankings` with
  `period: week`, one call per policy slice (`rails.openrouter.catalog.ranking_slices`: ⚖
  `programming`, a category, and `tool_calling`, a modality — the two slices the MCP gained by
  2026-10-19), the latest week's rows, the top N by tokens (⚖ `ranking_top_n` 30, the old proxy's
  `RANKINGS_TOP_N`). Rows are DATED permaslugs (`deepseek/deepseek-v4.1-flash-20260910`); the id is
  the stamp stripped (the old proxy's `_CAP_ID_RE`), so two stamps of one model are one candidate
  (⚖ their tokens summed — both are the model's traffic).
- **The benched set** — the MCP `list-benchmarks`, source `artificial-analysis`, keyed the same
  way; ⚖ a `:variant` id joins its family's row, as [GW-MODEL-TIERS](#gw-model-tiers)'s join does.
  Both MCP calls ride the openrouter ACCOUNT key (`catalog.account_ref`, a labelled Secret — the
  old proxy's `ROUTER_ACCOUNT_REF`; the gateway's own namespace gains the one get-secrets Role) over
  the MCP's JSON-RPC (`initialize`, then `tools/call`; a real User-Agent — Cloudflare 403s a bare
  client).
- **Candidates** = ranked ∩ benched. Per candidate, `GET <openrouter>/v1/models/<id>/endpoints`
  (public, unauthenticated), parsed by GW-RAIL-OPENROUTER's `parse_endpoints` into the
  [endpoint snapshot](../glossary.md#endpoint-snapshot) (`$defs.openrouter_snapshot`: the rows plus
  the model's ranking tokens and AA indices — what [#2743](https://github.com/teststuffstash/homelab/issues/2743)'s
  comparison needs on equal terms). ⚖ A candidate whose endpoints cannot be read is absent from
  this refresh (counted, never guessed); an MCP source that fails is `fetch-failed`, one that
  answers a shape the leg cannot read is `parse-failed`; a fresh snapshot with no model, or fewer
  than half the last good one's, is `implausible` — the last good snapshot stands.

### The entry canary

A `(model, provider)` cell new to the snapshot — or back from exclusion — is **`candidate`**, not
`eligible`: [selection](openai-chat.md#selection--the-gateways-own-evidence-never-exacto) pins only
`eligible` cells, and ⚖ a model none of whose cells has passed rides **unpinned** (the vendor's own
routing, exactly as before this leg — never refused for lack of a canary). A cell becomes
`eligible` when ONE canary ride completes a tool-call loop through the gateway on exactly that
cell: a session admitted by `POST /sessions` with **`canary: {model, provider}`** (the policy's
`canary.role` — `prober` — on rail openrouter, the harness the cell serves — `canary.harness`,
`opencode` — unless the body names another the rail speaks), pinned to that provider with
fallbacks off and **no failover**, whose outcome is the verdict: `clean` → `eligible`; any strike
(the consumer's class, or the gateway's own transport class) → `excluded` with the class, a
`candidate` again after `canary.cooldown_s` (⚖ 86400 s). A canary session is a session like any
other (a token, an env, the outcome endpoint), so its rides are metered by the gateway; its model
is the catalog's, not the policy's (⚖ [GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve)'s
one exception: the catalog is the entry gate the policy's lists are derived from). The checks, in
order: the cell is in the snapshot (`not-in-catalog`, `retry_after_s` = the next refresh), it is a
candidate (`canary-not-due` — already eligible, or excluded inside its cooldown: `retry_after_s` =
the cooldown's end), the budget, then the rail's slot count and credential as any admission.
Who RIDES the canaries is the jail's `gateway/scripts/canary-entrants.sh` (reads the view, launches
one prober ride per candidate cell through `agents/agent-session.sh`'s `AGENT_GATEWAY_CANARY`
knob — the ride names no model: the launcher's preflight refuses `--model` under
`AGENT_GATEWAY=sessions`, and the pod's provider + model are the admission's
`OPENCODE_CONFIG_CONTENT`); FU-161's scout keeps its digest, its canary leg for OpenRouter entrants
is superseded by this.

### The budget cap

⚖ Policy knobs, never code constants (`rails.openrouter.canary`): **`max_per_refresh`** canary
admissions between two catalog refreshes (3), and **`usd_per_day`** of metered canary spend (1.0 —
the gateway's own token accounting on canary sessions, priced at the cell's endpoint rates:
uncached input and cache reads at `in`, output at `out`, ⚖ an upper bound). Over either → the
canary defers **`canary-budget`** (`retry_after_s` = the next refresh or the hour, whichever first
⚖) and entrants stay `candidate`; `gateway_canary_budget_exhausted` reads 1 while the cap holds and
candidates wait — `GatewayCanaryBudgetExhausted` fires on it
(`argocd/resources/agent-gateway/prometheusrule.yaml`, promtool fixture
`openrouter-catalog.promtool-test`), beside `OpenRouterCatalogStale` (no good refresh for 24 h, or
no snapshot) and `OpenRouterCatalogParseFailed`. A failed canary excludes exactly its cell, never
the model.

World `policy-default · openrouter-catalog` ([worlds/README.md](../worlds/README.md#the-openrouter-catalog-world)):
the fake MCP answers the two slices and the AA benchmarks from the live MCP answers of 2026-10-19,
trimmed (13 ranked ids across the latest week, 7 benched, 7 candidates); the openrouter rail's
fake serves `/v1/models/<id>/endpoints` for `deepseek/deepseek-v4.1-flash` (M) and
`z-ai/glm-5.3-flash` (G) and 404 for the other five. T0 = the test clock. The account key is the
fixture Secret `agent-egress/router-account-key`.

| description | the fakes answer | last good || outcome | models | cells (candidate) |
|---|---|---||---|---|---|
| "a first refresh: ranked ∩ benched, then the endpoints per candidate" | mcp ok, endpoints ok | none || ok | 2 (M, G) of 7 candidates — 13 ranked, 7 benched, 5 unreadable | 15 |
| "a dated permaslug joins its id: two stamps of one model are one candidate ⚖" | the rankings carry M-20260910 and M-20261017 | — || ok | M once, its stamps' tokens summed per slice | — |
| "the MCP answers an error: fetch-failed, the last good kept" | mcp 503 | 2 || fetch-failed | 2 | 15 |
| "the MCP is unreachable: fetch-failed" | mcp down | 2 || fetch-failed | 2 | — |
| "a tool result that is not JSON is a parse failure ⚖" | mcp malformed | 2 || parse-failed | 2 | — |
| "rankings without dates are a parse failure" | rankings-undated | 2 || parse-failed | 2 | — |
| "no benched candidate: implausible, nothing taken ⚖" | benchmarks-empty | none || implausible | 0 | 0 |
| "a candidate whose endpoints read fails is absent; the refresh still lands ⚖" | endpoints-503 for G | none || ok | 1 (M) — 6 unreadable | 8 |
| "an endpoint without an uptime figure does not fail its model's parse ⚖" | endpoints-null-uptime for G (its first endpoint's `uptime_last_1d` `null`) | none || ok | 2 (M, G) — 5 unreadable; G's row carries `uptime_1d` null | 15 |
| "every endpoints read failing keeps the last good" | endpoints-503 for both | 2 || implausible | 2 | — |
| "no account key: fetch-failed, no MCP call" | the ref absent | none || fetch-failed | 0 (0 MCP calls) | — |
| "the MCP calls carry the account key and a client identity ⚖" | mcp ok | — || — | `authorization: Bearer <the account key>`; `user-agent: agent-gateway/<v> (openrouter-catalog)`; `initialize` then `tools/call` ×3 | — |
| "a PVC store keeps the snapshot and the cells across a restart" | refresh, a new gateway on the same DB, +3600 s | — || — | `age_s` 3600; 2 models; 15 candidate cells | — |

| description | arrange | body || decision | rail / model / harness | reason | retry_after_s | the cell after |
|---|---|---||---|---|---|---|---|
| "a new cell is a candidate: selection does not pin it ⚖" | refresh | worker ride on M (tier heavy) || dispatch | the upstream body carries no `provider` | — | — | candidate |
| "a canary session is admitted on a candidate cell, pinned to it ⚖" | refresh | prober, `canary: {M, deepinfra}` || dispatch | openrouter / M / opencode | — | — | the ride's upstream body pins deepinfra, `allow_fallbacks: false`; the row's `canary_provider` = deepinfra |
| "a clean canary makes the cell eligible: selection pins it" | the canary ride 200, outcome `clean` | worker ride on M || — | pinned deepinfra | — | — | eligible |
| "a struck canary excludes exactly its cell ⚖" | the canary ride answered upstream-500 | — || — | — | — | — | (M, deepinfra) excluded (`provider-5xx`) until T0 + 86400; (M, atlas-cloud) still candidate |
| "an excluded cell is a candidate again after the cooldown ⚖" | the same, +86400 s | prober, `canary: {M, deepinfra}` || dispatch | openrouter / M | — | — | — |
| "a canary on an eligible cell is not due ⚖" | (M, deepinfra) eligible | prober, `canary: {M, deepinfra}` || defer | — | canary-not-due | 21600 (the next refresh) | — |
| "a canary on an excluded cell inside its cooldown is not due" | (M, deepinfra) excluded at T0, +3600 s | prober, `canary: {M, deepinfra}` || defer | — | canary-not-due | 82800 | — |
| "a canary on a cell the snapshot lacks" | refresh | prober, `canary: {M, fireworks}` || defer | — | not-in-catalog | 21600 | — |
| "a canary names a model the snapshot lacks" | refresh | prober, `canary: {moonshotai/kimi-k3, deepinfra}` || defer | — | not-in-catalog | 21600 | — |
| "the canary role is the policy's ⚖" | refresh | worker, `canary: {M, deepinfra}` || 400 | — | malformed-body | — | — |
| "a canary never fails over ⚖" | the canary ride answered upstream-500 | — || 500 | the upstream calls: deepinfra only | — | — | — |

| description | arrange | body || decision | reason | retry_after_s | `gateway_canary_budget_exhausted` |
|---|---|---||---|---|---|---|
| "under budget: N entrants are canaried" | refresh | 3 canaries on three cells || dispatch ×3 | — | — | 0 |
| "at the cap the N+1th waits ⚖" | 3 admitted this refresh | a 4th canary || defer | canary-budget | 3600 | 1 |
| "a refresh opens the next N ⚖" | 3 admitted, then a refresh | a 4th canary || dispatch | — | — | 0 |
| "the day's spend at the cap defers ⚖" | one canary ride metered $1.12 (in 5M, out 1M at deepinfra 0.14 / 0.42) | the next canary || defer | canary-budget | 3600 | 1 |
| "the day rolls over" | the same, +86400 s | the next canary || dispatch | — | — | 0 |
| "spend is metered at the cell's endpoint price ⚖" | the same ride || — | — | `gateway_canary_spend_usd` 1.12 | — |

| description | event || series | value |
|---|---||---|---|
| "age is seconds since the last good refresh" | refresh at T0, read at T0 + 600 s || `gateway_openrouter_catalog_age_seconds` | 600 |
| "the model count of the last good snapshot" | refresh || `gateway_openrouter_catalog_models` | 2 |
| "every refresh is counted by outcome" | refresh ok, then mcp 503 || `gateway_openrouter_catalog_refresh_total{outcome="ok"}` / `{outcome="fetch-failed"}` | 1 / 1 |
| "the last outcome is 1, the others 0" | the same || `gateway_openrouter_catalog_last_outcome{outcome="fetch-failed"}` / `{outcome="ok"}` | 1 / 0 |
| "cells are counted by state" | refresh, one clean canary on (M, deepinfra), one struck on (M, atlas-cloud) || `gateway_openrouter_cells{state="candidate"}` / `eligible` / `excluded` | 13 / 1 / 1 |
| "canary verdicts are counted" | the same || `gateway_canary_rides_total{outcome="eligible"}` / `{outcome="excluded"}` | 1 / 1 |
| "the view's shape is the schema's" | refresh, `GET /catalog/openrouter` || exactly the `required` keys of `openrouter_output`, of a model row, of an endpoint row, of `canary` | — |

### Named gaps (rows that exist so the omission is visible)

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: no in-cluster canary trigger" | a refresh lands N candidate cells || they wait for the jail's `canary-entrants.sh` | the on-demand launcher is a jail verb; a cluster-side trigger (a CronWorkflow reading the view) is unbuilt |
| "⚑ gap: the Go rail's canary" | a new Go model in the Go catalog || no entry gate on the opencode rail | [#2743](https://github.com/teststuffstash/homelab/issues/2743): the same canary is the yardstick on both rails |
| "⚑ gap: the ranking's `other` bucket and a `:free` family" | a `:free` id in the ranking || joins its family's AA row; `other` is dropped | no fixture row carries a `:free` candidate (the latest week had none in the top of either slice) |
| "⚑ gap: a 429'd canary buys nothing" | a pinned canary whose every request is 429 — `kimi-k3@baseten` 2×200 then 7×429, `deepseek-v4-flash@deepinfra` 9×429 on 2026-10-20 || the cell stays `candidate`, judged 0, the admission spent | neither the consumer's class nor the gateway's transport class fires on a run of 429s; the ruling — a strike with class `429`, or a no-verdict that must not consume an admission — is [#2775](https://github.com/teststuffstash/homelab/issues/2775)'s |
| "⚑ gap: a pod roll opens a new window" | a redeploy || the catalog re-fetches at start, `admitted_this_refresh` and `gateway_canary_rides_total` restart from 0 (three windows in 70 min on 2026-10-20, none by the 6 h timer); spend and cell states persist | the per-refresh count should key on the persisted snapshot's `fetched_at`, the counters on the store ([#2775](https://github.com/teststuffstash/homelab/issues/2775)) |
| "⚑ gap: the view does not say which cells selection could pin" | `canary-entrants.sh` walking `candidate` cells || alphabetical, floors unknown to it — the first admission went to `open-inference`, fp4, eligible and never pinnable | a per-endpoint "passes the floors" flag in the view, or the launcher reading `rails.openrouter.providers` from the deployed policy, and a cheapest-first walk ([#2775](https://github.com/teststuffstash/homelab/issues/2775)) |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CATALOG-OR.md"

</details>

## GW-MODEL-TIERS

*The deployed policy's `rails.<rail>.models.{light,standard,heavy}` lists are the output of a
derivation over benchmark evidence, not a hand-picked set* — the
[tier evidence](../glossary.md#tier-evidence) (operator rulings 2026-10-18, FU-270) — *and the
unit every cell is ordered and chosen by is its* [cost per clean ride](../glossary.md#cost-per-clean-ride)
*, never a per-token price* (operator ruling 2026-10-19, homelab#2718; built as homelab#2743: on
OpenRouter the headline price is a 1/price² lottery over 20+ providers and a failed ride bills a
reviewer round + a coordinator re-entry on top; on the Go rail one flat fee buys every model). Three
parts, each a reviewable file in git:

- **The snapshot** — `argocd/resources/agent-gateway/benchmarks.json`
  (`$defs.benchmarks_snapshot`): per rail, every **candidate** policy id with its Artificial
  Analysis row (joined by the rule below), its **price** — the openrouter model's SELECTED
  endpoint's output/input price (`GET /catalog/openrouter` `selected`: after the floors and the
  entry canary, [§Selection](openai-chat.md#selection--the-gateways-own-evidence-never-exacto);
  **null until a cell passed the canary — never the headline**), the Go model's
  [Go price](../glossary.md#go-price) (`GET /catalog/opencode` `pricing`) — its clean-ride
  evidence (`rides`: the cell's clean and judged rides from the outcome store, and the prior) and
  its Go monthly limit. Written by `scripts/benchmarks-snapshot.sh` from three reads: the AA
  capability rows (⚖ the gateway itself never calls AA: the rows are the OLD proxy's weekly pull,
  `_capability_tick` → its router store's `capability(model, source, intelligence, coding, agentic,
  updated_ts)`, read out of that pod) and the gateway's own two catalog views. The snapshot
  rides beside the policy in the deploy (`GATEWAY_BENCHMARKS`): its age is
  `gateway_tier_evidence_age_seconds`, and **`TierEvidenceStale`** fires past ⚖ 7 days (the AA
  pull behind it is weekly; a comparison on a month-old price is a wrong answer with a confident
  face — the 10-18 snapshot read $0.144/M against a live $0.080/M a day later), or when no
  snapshot is mounted (`argocd/resources/agent-gateway/prometheusrule.yaml`, fixture
  `tier-evidence.promtool-test`).
- **The rules** — the policy's top-level `tiers` block (`$defs.tiers_block`), which the loader
  validates: `score` (one of `intelligence` | `coding` | `agentic`), `bands` (every tier, a
  fraction in (0, 1], `heavy ≥ standard ≥ light`), `cap` (a positive integer), and **`cost`** —
  the cost-per-clean-ride terms (`ride_tokens_out_m`, `strike_overhead_usd`, `min_rides`;
  [§Cost per clean ride](#cost-per-clean-ride)). Unknown keys refuse the load like every other
  policy block. The fixture worlds carry the same block so one loader shape holds everywhere.
- **The derivation + check** — `agent_gateway.tiers` (`derive`, `join_aa_id`, `same_model`,
  `cost_per_clean_ride`, `check`, `undecided`, `apply_text`; CLI `devbox run tiers -- snapshot |
  derive | check | apply`). The deployed lists EQUAL the derivation, order included — a test row
  runs the check, so a hand edit of a list fails the suite; `apply` rewrites exactly the decided
  tiers' lists in the file's own layout. ⚖ A tier whose derivation is **empty** — no benched,
  priced candidate reaches its band (the openrouter rail before its first eligible cell) — is
  **undecided**: the deployed list stands, `check` names it apart and never as a mismatch,
  `apply` refuses to write it.

### Cost per clean ride

⚖ For a cell with price `p` ($ per 1M output tokens), clean-ride rate `r` and the policy's
`tiers.cost` (`T` M output tokens a ride spends, `o` $ a failed ride costs on top of itself):
**`cost = p × T ÷ r + o × (1 ÷ r − 1)`** — one clean ride takes `1 ÷ r` rides, each at the cell's
price, and every failed one in between bills the strike overhead. `r` is **measured** from the
outcome store (clean rides ÷ judged rides — a ride = a session the cell served a 2xx to whose
latest outcome is reported, [GW-SESSIONS-OUTCOME](sessions.md#gw-sessions-outcome)) once the
cell has `min_rides` judged rides; before that a **prior** stands — the selected endpoint's
`uptime_1d ÷ 100` on openrouter (the same prior [§Selection](openai-chat.md#selection--the-gateways-own-evidence-never-exacto)
orders by), ⚖ 1.0 on the Go rail (one endpoint, no vendor uptime; the gap row). A rate of 0 is an
unaffordable cell. The deployed terms: `T` 0.01 (10k output tokens — the 30-day mean per session
of the two openai-dialect rails off the gateway's own ledger, 2026-10-20), `o` 0 (⚖ UNMEASURED:
the term exists so the measurement has a home — the gap row; at 0 the order is price over clean
rate), `min_rides` 5 (the same number as `providers.min_rides`; two knobs because two rules).

| description | out $/M | rides (clean / judged, prior) | `tiers.cost` (T · overhead · min_rides) || rate (basis) | $ per clean ride |
|---|---|---|---||---|---|
| "a clean cell costs its price for one ride's tokens ⚖" | 0.42 | 0 / 0, prior 1.0 | 0.01 · 0 · 5 || 1 (prior) | 0.0042 |
| "under min_rides the prior stands ⚖" | 0.42 | 2 / 4, prior 0.9 | 0.01 · 0 · 5 || 0.9 (prior) | 0.004667 |
| "a measured clean rate of one half doubles the cost ⚖" | 0.42 | 3 / 6, prior 1.0 | 0.01 · 0 · 5 || 0.5 (measured) | 0.0084 |
| "the strike overhead is paid once per failed ride ⚖" | 0.42 | 3 / 6, prior 1.0 | 0.01 · 0.10 · 5 || 0.5 (measured) | 0.1084 |
| "a cell with no clean ride yet is unaffordable ⚖" | 0.42 | 0 / 5, prior 1.0 | 0.01 · 0 · 5 || 0 (measured) | ∞ |

### The Go price

⚖ The opencode rail has no per-token price: one monthly fee buys an allowance of every listed
model at list prices. Its price per model is therefore DERIVED: **the list price × the plan's
discount, `fee ÷ max(the rail's trailing-30-day list-priced draw, the model's monthly limit)`** —
the fee buys at least the model's own allowance (`promise`), and a busier rail makes every Go
token cheaper (`measured`); an unlimited model prices at 0 (`unlimited`). The fee is the Go
page's Plan table ([GW-CATALOG-GO](#gw-catalog-go), never a policy copy — ruling 5); the draw is
the gateway's own ledger at the catalog's list rates, the window draw's arithmetic
([GW-SESSIONS-ADMIT §Capacity](sessions.md#capacity--the-ladders-capacity-half)); the model's
windows stay the gate — a window at its threshold holds the cell whatever its price. Shown on
`GET /catalog/opencode` `pricing` (`output.pricing`), read by the snapshot and the rail choice.
Rows run against the world's Go catalog (plan `go`: fee $10/month; `deepseek-v4.1-flash` $80/month
at list 0.15 in / 0.60 out; `claude-haiku-5-5` $15 at 0.10 / 0.50; `longcat-2.5-preview-free`
unlimited), T0 = Fri 2027-01-15 08:00:00Z.

| description | the rail's trailing-30-day ledger || model | discount | basis | out $/M · in $/M |
|---|---||---|---|---|---|
| "the plan's promise prices an idle rail ⚖" | nothing || `deepseek-v4.1-flash` | 10 ÷ 80 = 0.125 | promise | 0.075 · 0.01875 |
| "each model's own allowance is its promise ⚖" | nothing || `claude-haiku-5-5` | 10 ÷ 15 = 0.666667 | promise | 0.333333 · 0.066667 |
| "a rail drawing past the allowance is priced on the meter ⚖" | one worker ride at T0 + 2 h (off-peak) drawing in 1000M at $0.15 + out 100M at $0.60 = $210 at list || `deepseek-v4.1-flash` | 10 ÷ 210 = 0.047619 | measured | 0.028571 · 0.007143 |
| "an unlimited model prices at 0 ⚖" | nothing || `longcat-2.5-preview-free` | 0 | unlimited | 0 · 0 |
| "no fee read: no price ⚖" | the docs snapshot written before the Plan table (its body without `plan_fees`) || `deepseek-v4.1-flash` | null | null | null · null |
| "the price shows on GET /catalog/opencode ⚖" | nothing || `pricing`: `fee_usd_month` 10, `draw_30d_usd` 0, `models[deepseek-v4.1-flash]` {out 0.075, in 0.01875, discount 0.125, basis promise, rides 0 / 0} | | | |

### The rail choice

*The gateway chooses between `openrouter` and `opencode-go` for one model on equal terms*
(operator acceptance 2026-10-19, homelab#2743: every bad OpenRouter provider filtered out first —
fp8 vs fp8, tool-call support, uptime — then price per CLEAN ride, a failed provider relaunched
transparently). ⚖ When the admission's tier names ONE model on two of the role's allowed rails — a
[twin](../glossary.md#twin): the same tail after the rail prefix, a `:variant` and the vendor
are stripped, `-N-N` ↔ `-N.N` (`same_model`, one rule, no table; a `claude/` alias twins nothing)
— the walk's rail order puts the rail whose twin cell costs less per clean ride FIRST, with that
twin at the head of its list; everything else about [GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit)'s
walk stands (the other rail is still walked when the first yields nothing; the tier's lists
decide which models exist — the choice never adds one). Each twin's standing: the Go cell at the
Go price, its window or its catalog standing holding it (`headroom` — a window at its threshold
or a 429 cooldown; `not-in-catalog`); the openrouter cell at its SELECTED endpoint's price —
the floors, the entry canary, the task's strikes and the cooldowns applied as [§Selection](openai-chat.md#selection--the-gateways-own-evidence-never-exacto)
does (`no-eligible-endpoint` when nothing is left to price: no cell has passed the canary, or none
clears the floors); each over the cell's clean-ride rate. A twin struck for the task is the retry
contract's business, not the choice's (no choice; the walk skips it). Both unpriced → no choice:
the role's order, and the walk's own defer. The answer carries **`rail_choice: {rail, over,
reason}`** (`null` when no twin) and `gateway_rail_choice_total{model, rail, reason}` counts it
(`model` = the twin's openrouter spelling, the provider families' bound). Reasons: `price` (cheaper
per clean ride and by price alone; a tie goes to the role's order), `clean-rate` (the measured rate
flipped the price order), `headroom`, `not-in-catalog`, `no-eligible-endpoint`. A failed-over
request bills the serving provider: its row names that provider, its outcome judges that cell
([§Failover](openai-chat.md#failover--before-the-first-byte-only) — the choice does not change it).

World `policy-default · openrouter-endpoints` (the snapshot of `deepseek/deepseek-v4.1-flash` = M,
every cell eligible) with the Go catalog above. A worker with harness opencode at tier **light**:
opencode names `opencode-go/deepseek-v4.1-flash` (MG), openrouter `deepseek/deepseek-v4-flash`
then M — M and MG are twins. Go's promise $0.075/M vs deepinfra's $0.42/M, both at the prior rate.

| description | arrange | body || decision | rail | model | `rail_choice` | `gateway_rail_choice_total{model=M,rail,reason}` |
|---|---|---||---|---|---|---|---|
| "Go wins with free headroom and an equal clean rate ⚖" | — | worker, tier light || dispatch | opencode | MG | opencode over openrouter: `price` | `{rail="opencode",reason="price"}` 1 |
| "openrouter wins when Go's window is near its share ⚖" | a worker ride on opencode drew in 30M / out 3.2M at T0 ($12.84 ≥ 0.80 × $16) | the same || dispatch | openrouter | M (the twin at the head, ahead of the list's first id) | openrouter over opencode: `headroom` | `{rail="openrouter",reason="headroom"}` 1 |
| "openrouter wins when Go's clean rate is lower ⚖" | six judged Go rides on MG, one clean (rate ⅙: $0.075 ÷ 0.1667 = $0.45/M per clean ride, past deepinfra's $0.42) | the same || dispatch | openrouter | M | openrouter over opencode: `clean-rate` | `{rail="openrouter",reason="clean-rate"}` 1 |
| "no eligible openrouter endpoint: Go ⚖" | the snapshot trimmed to the ineligible endpoints (`openrouter-endpoints-ineligible`) | the same || dispatch | opencode | MG | opencode over openrouter: `no-eligible-endpoint` | `{rail="opencode",reason="no-eligible-endpoint"}` 1 |
| "no openrouter cell has passed the entry canary yet: Go ⚖" | every cell of M set back to `candidate` (the production state of 2026-10-20) | the same || dispatch | opencode | MG | opencode over openrouter: `no-eligible-endpoint` | `{rail="opencode",reason="no-eligible-endpoint"}` 1 |
| "both twins held: no choice, the walk defers with the hold that lifts first ⚖" | the window draw above; the snapshot ineligible; the task's earlier ride struck `no-verdict` on `deepseek/deepseek-v4-flash` | the same, that task || defer | — | — | — (a defer) | no series; reason `no-eligible-provider`, `retry_after_s` 60 |
| "no twin at the tier: the role's order, no choice" | — | worker, tier standard (opencode MG; openrouter `deepseek/deepseek-v4-flash`) || dispatch | opencode | MG | `null` | no series |
| "the choice survives a failover: the ride's rows name the serving provider, its outcome judges that cell ⚖" | the window draw above; the openrouter fake's deepinfra attempt answers 500 | the same, then one ride and a `clean` outcome || dispatch | openrouter | M | `headroom` | the session's request rows deepinfra 500 then atlas-cloud 200; `GET /catalog/openrouter` rides: atlas-cloud 1 / 1, deepinfra 0 / 0 |

| description | the mounted snapshot || `gateway_tier_evidence_age_seconds` |
|---|---||---|
| "age is seconds since snapshot_at ⚖" | a file with `snapshot_at` T0 − 600, `GATEWAY_BENCHMARKS` naming it || 600 |
| "no snapshot mounted, no series" | `GATEWAY_BENCHMARKS` naming a missing file || absent |

### The rulings ⚖

Each row is proven against the committed snapshot + the deployed policy (skipped when absent);
the two remaining rulings — the lists EQUAL the derivation, the fixture worlds are exempt — are
the ⚖ rows of *The deployed policy* below.

| description | the ruling || where it binds, and what the row checks |
|---|---||---|
| "the score is the Artificial Analysis intelligence index ⚖" | the one axis with full coverage: `coding` / `agentic` are null on most new rows (`claude-haiku-5.5`, `gpt-6-luna`, `mimo-v2.6-*` carry only `intelligence`) || `tiers.score: intelligence` in the deployed policy; every benched candidate row carries `intelligence`, at least one lacks `coding`; the other two axes are loadable, unused (gap row) |
| "a tier is a band of the rail's best ⚖" | within a rail, a benched candidate is `heavy` when its score ≥ 0.90 × the rail's top score, `standard` when ≥ 0.75 ×, `light` when ≥ 0.50 ×; a model can sit in several tiers || `tiers.bands` `{heavy: 0.9, standard: 0.75, light: 0.5}` in the deployed policy; every id in a deployed list scores ≥ its band × its rail's top |
| "each list is cheapest per clean ride first, capped at 3 ⚖" | order = cost per clean ride ascending, then input price, then score descending, then id (the last three break ties — the gateway's own choice); the list keeps the first `cap` || `tiers.cap: 3`; every deployed DECIDED priced-rail list has ≤ 3 ids with non-decreasing cost per clean ride (`row_cost` over the snapshot row under the deployed `tiers.cost`) |
| "the subscription rail has no price: score ascending is its cost proxy ⚖" | the `anthropic` rail's candidates carry no per-token price (one flat subscription); its lists are ordered by score ascending — the cheapest-capable first || `PRICELESS_RAILS = (anthropic,)` in `agent_gateway.tiers`; every anthropic snapshot row has no price and each deployed anthropic list is strictly score-ascending; the gap row below |
| "the candidates per rail ⚖" | opencode = the Go catalog's `listed` models with a `monthly_limit_usd` under the deployed plan (`opencode-go/<id>`), each at the Go price (`promise` / `measured` / `unlimited`, or unpriced before the fee is read); openrouter = the OpenRouter catalog's models ([GW-CATALOG-OR](#gw-catalog-or): the weekly ranking ∩ AA-benched), each at its SELECTED endpoint's price (`endpoint`, with the provider) or unpriced — never the headline, never the old proxy's table; anthropic = the policy's three aliases `claude/haiku`, `claude/sonnet`, `claude/opus` (an argument of the snapshot script, never code), unpriced || `build_snapshot`; in the snapshot every opencode key is `opencode-go/<id>` with `price_basis` in {promise, measured, unlimited, null}, every openrouter key is a `vendor/model` id with `price_basis` in {endpoint, null} and a `provider` exactly when priced, the anthropic keys = the deployed rail's `claude/` aliases, unpriced; `sources.capability.source` = `artificial-analysis`, `sources.openrouter_catalog.fetched_at` present |
| "the join to the AA row is a rule, not a table ⚖" | AA ids are `vendor/model` with dotted versions; Go ids are bare: join on the part after the vendor `/` with `-N-N` ↔ `-N.N` normalisation, a `:variant` suffix dropped, the vendor kept when the policy id names one; the three aliases join the NEWEST `anthropic/claude-<alias>-<version>` row by version; no match, or more than one, = unbenched || `join_aa_id`; every snapshot row's `aa_id` is what `join_aa_id` returns over the snapshot's AA ids (no row is a hand-written pair); the rows below |
| "unbenched never tiers ⚖" | a candidate with no AA row is in no list, whatever its price (the free `beam-free` and `longcat-2.5-preview-free` stay out); so does an unpriced candidate on a priced rail (every openrouter model until a cell passed the entry canary) || `derive`; no id in a deployed list has a null `aa_id`, nor a null `out_price` on a priced rail |

### The bands, on a hand-written rail

A six-candidate priced rail `fx` under `score: intelligence`, bands 0.9 / 0.75 / 0.5, cap 3.
Scores and prices are the row's inputs, the lists are arithmetic: top = 50, so heavy ≥ 45,
standard ≥ 37.5, light ≥ 25.

| description | candidates (id: score · out / in $ per 1M) || light | standard | heavy |
|---|---||---|---|---|
| "heavy = within 0.90 of the rail's top, cheapest first ⚖" | `fx/top` 50 · 2.0/0.5, `fx/near` 46 · 1.0/0.2, `fx/mid` 40 · 0.5/0.1, `fx/low` 26 · 0.1/0.05, `fx/far` 20 · 0.05/0.01, `fx/none` unbenched · 0/0 || — | — | `fx/near`, `fx/top` |
| "standard = within 0.75 ⚖" | the same || — | `fx/mid`, `fx/near`, `fx/top` | — |
| "light = within 0.50, the cap drops the 4th by price ⚖" | the same || `fx/low`, `fx/mid`, `fx/near` (`fx/top` is 4th at 2.0) | — | — |
| "a model sits in several tiers" | the same || `fx/near` in all three | | |
| "an unbenched candidate never tiers, however cheap ⚖" | the same (`fx/none` at 0/0 has no AA row) || `fx/none` in none | | |
| "an unpriced candidate on a priced rail never tiers ⚖" | the same + `fx/nopx` 49 · no price || `fx/nopx` in none; top stays 50 | | |
| "a price tie breaks by input price, then score, then id ⚖" | rail `fxt`: `fxt/a` 40 · 0.5/0.2, `fxt/b` 44 · 0.5/0.1, `fxt/c` 44 · 0.5/0.2 || — | — | `fxt/b`, `fxt/c`, `fxt/a` |
| "the axis is the policy's: the same rail under `score: coding`" | `fx` with coding `top` 10, `near` 60, `mid` 55, `low` 50, `far` 5 || — | — | `fx/mid`, `fx/near` (top = 60, heavy ≥ 54) |
| "the subscription rail orders by score ascending ⚖" | rail `anthropic`: `claude/fx-a` 40, `claude/fx-b` 55, `claude/fx-c` 60, no prices || `claude/fx-a`, `claude/fx-b`, `claude/fx-c` | `claude/fx-b`, `claude/fx-c` | `claude/fx-b`, `claude/fx-c` |
| "no benched candidate: empty lists, which apply refuses to write" | rail `fx-empty`: `fx/none` only || `[]` — `apply_text` raises naming `fx-empty.light` | | |
| "a measured clean rate reorders a list ⚖" | `fx` + `fx/mid` rides 2 / 6 (rate ⅓: $0.5 ÷ ⅓ = $1.5 per 1M of output, past `fx/near`'s $1.0) || — | `fx/near`, `fx/mid`, `fx/top` | — |
| "a tier with no priced candidate is undecided: check passes it, apply refuses it ⚖" | rail `fx-unpriced`: `fx/a` 50 · no price || derive `[]` ×3; `undecided` names `fx-unpriced` light/standard/heavy; `check` = `{}` against a policy listing `fx/a`; `apply_text` raises naming `fx-unpriced.light` | | |

### The twin rule

| description | a | b || twins |
|---|---|---||---|
| "a Go id and its openrouter spelling are twins ⚖" | `opencode-go/deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash` || yes |
| "the dotted and the dashed version are twins" | `opencode-go/claude-haiku-5-5` | `anthropic/claude-haiku-5.5` || yes |
| "a variant twins its family" | `inclusionai/ling-3.0-flash:free` | `inclusionai/ling-3.0-flash` || yes |
| "two vendors' spellings are not twins ⚖" | `deepseek/deepseek-v4.1-flash` | `other/deepseek-v4.1-flash` || no |
| "a suffix is not a twin" | `opencode-go/glm-5.3` | `z-ai/glm-5.3-flash` || no |
| "an alias twins nothing ⚖" | `claude/haiku` | `opencode-go/claude-haiku-5-5` || no |
| "the same id is not a twin" | `deepseek/deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash` || no |

### The id join

| description | policy id | AA ids present || joins |
|---|---|---||---|
| "a Go id joins the dotted AA id ⚖" | `opencode-go/claude-haiku-5-5` | `anthropic/claude-haiku-5.5`, `anthropic/claude-haiku-4.5` || `anthropic/claude-haiku-5.5` |
| "a dotted Go id joins as is" | `opencode-go/glm-5.3` | `z-ai/glm-5.3`, `z-ai/glm-5.3-flash` || `z-ai/glm-5.3` |
| "a Go id the table lacks is unbenched" | `opencode-go/beam-free` | (the two above) || none |
| "a suffix is not a match" | `opencode-go/hy3` | `tencent/hy3-preview` || none |
| "two vendors' rows for one bare id: unbenched ⚖" | `opencode-go/gpt-6-luna` | `openai/gpt-6-luna`, `other/gpt-6-luna` || none |
| "an alias joins the newest row of its family by version ⚖" | `claude/opus` | `anthropic/claude-opus-5`, `anthropic/claude-opus-5.5`, `anthropic/claude-opus-4.1` || `anthropic/claude-opus-5.5` |
| "an alias with no row of its family is unbenched" | `claude/haiku` | (the three opus rows) || none |
| "an openrouter id keeps its vendor" | `deepseek/deepseek-v4-flash` | `deepseek/deepseek-v4-flash`, `other/deepseek-v4-flash` || `deepseek/deepseek-v4-flash` |
| "a `:free` variant joins its family ⚖" | `inclusionai/ling-3.0-flash:free` | `inclusionai/ling-3.0-flash` || `inclusionai/ling-3.0-flash` |

### The `tiers` block

| description | `tiers` in an otherwise `policy-default` document || the policy load |
|---|---||---|
| "the block loads" | `{score: intelligence, bands: {heavy: 0.9, standard: 0.75, light: 0.5}, cap: 3}` (the world's) || loads; `Policy.tiers` = those values |
| "an unknown key refuses the load" | + `foo: 1` || refused, naming `tiers` |
| "an unknown score axis refuses the load" | `score: vibes` || refused, naming `tiers.score` |
| "a band above 1 refuses the load" | `bands.heavy: 1.5` || refused, naming `tiers.bands.heavy` |
| "a zero band refuses the load" | `bands.light: 0` || refused, naming `tiers.bands.light` |
| "bands out of order refuse the load" | `bands.standard: 0.95` (heavy 0.9) || refused, naming `heavy >= standard >= light` |
| "a missing tier band refuses the load" | `bands` without `light` || refused, naming `light` |
| "a non-positive cap refuses the load" | `cap: 0` || refused, naming `tiers.cap` |
| "no block: the policy loads with no rules, and the check refuses to run ⚖" | `tiers` absent || loads, `Policy.tiers` None; `check()` raises naming `tiers` |
| "no cost terms refuse the load ⚖" | `cost` absent || refused, naming `tiers.cost` |
| "a non-positive ride size refuses the load" | `cost.ride_tokens_out_m: 0` || refused, naming `tiers.cost.ride_tokens_out_m` |
| "a non-positive min_rides refuses the load" | `cost.min_rides: 0` || refused, naming `tiers.cost.min_rides` |

### The deployed policy

Against `argocd/resources/agent-gateway/benchmarks.json` + `policy.json` (skipped when absent).

| description | input || verdict |
|---|---||---|
| "the deployed tier lists equal the derivation ⚖" | the committed snapshot + the deployed `tiers` block || `check()` = `{}` — every `rails.<rail>.models.<tier>` is the derived list, in order |
| "a hand edit of a list fails the check" | the deployed policy with `rails.opencode.models.heavy` reversed || `check()` names `opencode.heavy` with the derived list as expected |
| "the snapshot is the schema's shape" | the committed snapshot || exactly the `required` keys of `$defs.benchmarks_snapshot`, of a source and of a candidate row |
| "the fixture worlds carry the block, not the derivation ⚖" | `policy-default` + the committed snapshot || the world's `tiers` = the deployed block; `check()` on the world is NOT empty (its lists are fixture ids) and no suite row runs it |
| "an undecided tier keeps its deployed list ⚖" | the committed snapshot's undecided tiers (2026-10-20: every openrouter tier — no cell has passed the entry canary, so no openrouter price exists) || `check()` = `{}`; `undecided()` names them; each named tier's deployed list is non-empty (the last decided derivation stands until evidence exists) |

### Named gaps (rows that exist so the omission is visible)

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: no price for the subscription rail" | the `anthropic` rail || score ascending as the cost proxy | a subscription's marginal cost per model is not a per-token price and the subscription's fee buys no listed allowance to divide (the Go rail's derivation needs one); the gateway has no ledger for it (the cost ledger is a gap on [GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit)) |
| "⚑ gap: coding / agentic unused" | `tiers.score: coding` || loads and derives — but most new rows carry null there (the ruling) | AA's task indices have no coverage on the newest models; revisit when they do |
| "⚑ gap: the snapshot is hand-refreshed" | a stale `snapshot_at` || `TierEvidenceStale` names it; nothing re-cuts it | no schedule runs `benchmarks-snapshot.sh`: the re-cut is a jail verb and a PR (the alert is the belt, the operator the hands) |
| "⚑ gap: a Go-only id spelling joins nothing" | `gemini-4-argon-contributor`, `muse-spark-1.3-contributor`, `hy3`, `hy4-preview`, `qwen3.8-flash`, `space-bunny` || unbenched (9 of 29 listed Go models) | the vendor's `-contributor` / `-preview` suffixes and bare family ids have no AA spelling; a per-id alias would be a table, which the ruling forbids |
| "⚑ gap: the Go rail's quantization is undeclared" | a Go cell beside an fp8 openrouter cell || compared as if on equal terms | the vendor states no quantization for its endpoints (checked 2026-10-19); the entry canary is the common yardstick both rails lack today ([GW-CATALOG-OR](#gw-catalog-or)'s "the Go rail's canary" row) — a Go cell gets no entry gate, its clean-rate prior is 1.0 |
| "⚑ gap: the strike overhead is unmeasured" | a failed ride || `tiers.cost.strike_overhead_usd` 0: the order is price over clean rate | the reviewer round + the coordinator re-entry a failed ride costs ride the subscription (no per-token price) — the term has a home and no measurement |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-MODEL-TIERS.md"

</details>
