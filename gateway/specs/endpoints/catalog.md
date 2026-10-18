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
store, and shows both here and on `/metrics`. Admission reads the snapshot — the Go window
draw's prices, each model's own windows, `not-in-catalog`
([GW-SESSIONS-ADMIT §Capacity](sessions.md#capacity--the-ladders-capacity-half)); this page owns only the reading. The
design input and the operator's rulings are the spike's §Rulings.

This page is *what the gateway knows about models and where it comes from*, so it carries a
second rule: [GW-MODEL-TIERS](#gw-model-tiers) — the deployed policy's per-(rail, tier) model
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
| [GW-CATALOG-GO](#gw-catalog-go) | `output`, `$defs.config_snapshot`, `$defs.docs_snapshot`, metrics `families.gateway_go_catalog_*` | — | v0 — the read leg; admission reads it ([GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit) §Capacity owns those rows); models.dev as a fallback source and a liveness signal are `⚑ gap` (rows below) |
| [GW-MODEL-TIERS](#gw-model-tiers) | `$defs.benchmarks_snapshot` (the committed `argocd/resources/agent-gateway/benchmarks.json`), `$defs.tiers_block` (the policy's `tiers`) | — (the loader refuses a malformed `tiers` block; `tiers check` exits 1 on a drifted list) | v0 — the derivation, the committed snapshot and the equality check; a price for the subscription rail, the coding/agentic axes, a refresh schedule and a staleness alert are `⚑ gap` (rows below) |

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
| "no share sentence is a parse failure ⚖" | 5 | `docs-no-shares` || parse-failed | the last good |
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
| "the peak hours come from the page ⚖" | `docs-ok`'s *"Peak hours are 01:00-04:00 and 06:00-10:00 UTC, Monday through Friday"* || `peak_hours_utc` `[[1, 4], [6, 10]]`, `peak_weekdays` mon–fri |
| "the window shares come from the page ⚖" | *"5-hour — 20% of the monthly limit; weekly — 50%; and monthly — 100%"* || `window_shares` 5h 0.2 · 7d 0.5 · 30d 1.0; `deepseek-v4.1-flash` `windows_usd` 16 / 40 / 80 |
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

What the policy no longer holds (ruling 5): the vendor facts live in the snapshot, so a policy that
still carries one refuses to load — a stale hand copy can never shadow the catalog.

| description | `rails.opencode.admission` in an otherwise `policy-default` document || the policy load |
|---|---||---|
| "a price row in the policy refuses the load" | `window_draw.prices` = the old `deepseek-v4.1-flash` row || refused, naming `prices` |
| "a fallback price refuses the load" | `window_draw.fallback` = 9.00 / 9.00 || refused, naming `fallback` |
| "a window budget refuses the load" | `window_draw.windows.5h.budget_usd` = 12 || refused, naming `budget_usd` |
| "a window the vendor gives no share refuses the load" | `window_draw.windows.1d` || refused, naming `windows.1d` |
| "an unknown latch scope refuses the load" | `latch_scope: rail` || refused, naming `latch_scope` |

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
| "⚑ gap: models.dev as a fallback" | the console config unreachable for a day || the last good snapshot, `GoCatalogStale` | the spike's §F4: `models.dev/api.json` mirrors the vendor and carries the only machine-readable `deprecated` marker |
| "⚑ gap: listed is not alive" | a listed id that answers 400 `Model is unavailable` || listed | the spike's §F3 / gap 4: no vendor source is a liveness signal; the shadow cells and the 4xx/5xx belts are |
| "⚑ gap: a vendor reset time" | a Go 429 || — (this leg reads no usage) | the spike's gap 6: no real Go 429 has been observed |
| "⚑ gap: the OpenRouter rail's registry" | an openrouter session || no catalog | the old proxy reads `/api/v1/models/<id>/endpoints` for its provider pin and price (`compute_pin`, `MARKET_TTL_S`); the gateway's openrouter rail forwards the policy model with no registry (the spike's §Proposed design) |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CATALOG-GO.md"

</details>

## GW-MODEL-TIERS

*The deployed policy's `rails.<rail>.models.{light,standard,heavy}` lists are the output of a
derivation over benchmark evidence, not a hand-picked set* — the
[tier evidence](../glossary.md#tier-evidence) (operator rulings 2026-10-18, FU-270). Three
parts, each a reviewable file in git:

- **The snapshot** — `argocd/resources/agent-gateway/benchmarks.json`
  (`$defs.benchmarks_snapshot`): per rail, every **candidate** policy id with its Artificial
  Analysis row (joined by the rule below), its output/input price in $ per 1M tokens and its Go
  monthly limit. Written by `scripts/benchmarks-snapshot.sh` from three live reads, and only
  the candidate rows (not the capability table's 345). ⚖ The gateway itself never calls AA or
  the OpenRouter MCP: the capability rows are the OLD proxy's weekly pull (`_capability_tick` →
  its router store's `capability(model, source, intelligence, coding, agentic, updated_ts)`),
  read out of that pod; the Go rows are the gateway's own `GET /catalog/opencode`
  ([GW-CATALOG-GO](#gw-catalog-go) — the same snapshot admission reads); the OpenRouter prices
  are the public `GET https://openrouter.ai/api/v1/models` (`pricing.completion` /
  `pricing.prompt`, per token, scaled to $/1M; a negative = dynamic = no price).
- **The rules** — the policy's top-level `tiers` block (`$defs.tiers_block`), which the loader
  validates: `score` (one of `intelligence` | `coding` | `agentic`), `bands` (every tier, a
  fraction in (0, 1], `heavy ≥ standard ≥ light`), `cap` (a positive integer). Unknown keys
  refuse the load like every other policy block. The fixture worlds carry the same block so one
  loader shape holds everywhere.
- **The derivation + check** — `agent_gateway.tiers` (`derive`, `join_aa_id`, `check`,
  `apply_text`; CLI `devbox run tiers -- snapshot | derive | check | apply`). The deployed
  lists EQUAL the derivation, order included — a test row runs the check, so a hand edit of a
  list fails the suite; `apply` rewrites exactly the three rails' `models` blocks in the
  file's own layout.

### The rulings ⚖

Each row is proven against the committed snapshot + the deployed policy (skipped when absent);
the two remaining rulings — the lists EQUAL the derivation, the fixture worlds are exempt — are
the ⚖ rows of *The deployed policy* below.

| description | the ruling || where it binds, and what the row checks |
|---|---||---|
| "the score is the Artificial Analysis intelligence index ⚖" | the one axis with full coverage: `coding` / `agentic` are null on most new rows (`claude-haiku-5.5`, `gpt-6-luna`, `mimo-v2.6-*` carry only `intelligence`) || `tiers.score: intelligence` in the deployed policy; every benched candidate row carries `intelligence`, at least one lacks `coding`; the other two axes are loadable, unused (gap row) |
| "a tier is a band of the rail's best ⚖" | within a rail, a benched candidate is `heavy` when its score ≥ 0.90 × the rail's top score, `standard` when ≥ 0.75 ×, `light` when ≥ 0.50 ×; a model can sit in several tiers || `tiers.bands` `{heavy: 0.9, standard: 0.75, light: 0.5}` in the deployed policy; every id in a deployed list scores ≥ its band × its rail's top |
| "each list is cheapest-first by output price, capped at 3 ⚖" | order = output price ascending, then input price, then score descending, then id (the last three break ties — the gateway's own choice); the list keeps the first `cap` || `tiers.cap: 3`; every deployed priced-rail list has ≤ 3 ids with non-decreasing `out_price`; the Go price is the catalog's base `cost[0].out`, the OpenRouter price `pricing.completion` × 1M |
| "the subscription rail has no price: score ascending is its cost proxy ⚖" | the `anthropic` rail's candidates carry no per-token price (one flat subscription); its lists are ordered by score ascending — the cheapest-capable first || `PRICELESS_RAILS = (anthropic,)` in `agent_gateway.tiers`; every anthropic snapshot row has no price and each deployed anthropic list is strictly score-ascending; the gap row below |
| "the candidates per rail ⚖" | opencode = the Go catalog's `listed` models with a `monthly_limit_usd` under the deployed plan (`opencode-go/<id>`); openrouter = every `models.*.ids.openrouter` value of `model-classes.json` (the old proxy's table — gap row); anthropic = the policy's three aliases `claude/haiku`, `claude/sonnet`, `claude/opus` (an argument of the snapshot script, never code) || `build_snapshot`; in the snapshot every opencode key is `opencode-go/<id>`, the openrouter keys = `model-classes.json`'s `models.*.ids.openrouter` values, the anthropic keys = the deployed rail's `claude/` aliases, `sources.capability.source` = `artificial-analysis` |
| "the join to the AA row is a rule, not a table ⚖" | AA ids are `vendor/model` with dotted versions; Go ids are bare: join on the part after the vendor `/` with `-N-N` ↔ `-N.N` normalisation, a `:variant` suffix dropped, the vendor kept when the policy id names one; the three aliases join the NEWEST `anthropic/claude-<alias>-<version>` row by version; no match, or more than one, = unbenched || `join_aa_id`; every snapshot row's `aa_id` is what `join_aa_id` returns over the snapshot's AA ids (no row is a hand-written pair); the rows below |
| "unbenched never tiers ⚖" | a candidate with no AA row is in no list, whatever its price (the free `beam-free` and `longcat-2.5-preview-free` stay out); so does an unpriced candidate on a priced rail (`inclusionai/ling-3.0-flash:free` is benched but no longer on OpenRouter's list) || `derive`; no id in a deployed list has a null `aa_id`, nor a null `out_price` on a priced rail |

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

### The deployed policy

Against `argocd/resources/agent-gateway/benchmarks.json` + `policy.json` (skipped when absent).

| description | input || verdict |
|---|---||---|
| "the deployed tier lists equal the derivation ⚖" | the committed snapshot + the deployed `tiers` block || `check()` = `{}` — every `rails.<rail>.models.<tier>` is the derived list, in order |
| "a hand edit of a list fails the check" | the deployed policy with `rails.opencode.models.heavy` reversed || `check()` names `opencode.heavy` with the derived list as expected |
| "the snapshot is the schema's shape" | the committed snapshot || exactly the `required` keys of `$defs.benchmarks_snapshot`, of a source and of a candidate row |
| "the fixture worlds carry the block, not the derivation ⚖" | `policy-default` + the committed snapshot || the world's `tiers` = the deployed block; `check()` on the world is NOT empty (its lists are fixture ids) and no suite row runs it |

### Named gaps (rows that exist so the omission is visible)

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: no price for the subscription rail" | the `anthropic` rail || score ascending as the cost proxy | a subscription's marginal cost per model is not a per-token price; the gateway has no ledger for it (the cost ledger is a gap on [GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit)) |
| "⚑ gap: coding / agentic unused" | `tiers.score: coding` || loads and derives — but most new rows carry null there (the ruling) | AA's task indices have no coverage on the newest models; revisit when they do |
| "⚑ gap: the snapshot is hand-refreshed, nothing alerts on its age" | a `snapshot_at` a month old || the suite still passes | no schedule runs `benchmarks-snapshot.sh`, no `gateway_*` family carries the snapshot's age; the AA pull behind it is the old proxy's weekly tick |
| "⚑ gap: the openrouter candidate set is the old proxy's table" | `model-classes.json` `models.*.ids.openrouter` || 11 ids, 6 benched, 5 priced — `moonshotai/kimi-k3` alone reaches `heavy` / `standard` | the gateway's openrouter rail has no registry of its own ([GW-CATALOG-GO](#gw-catalog-go) gap row); a Go-shaped catalog leg for OpenRouter would widen the set |
| "⚑ gap: a Go-only id spelling joins nothing" | `gemini-4-argon-contributor`, `muse-spark-1.3-contributor`, `hy3`, `hy4-preview`, `qwen3.8-flash`, `space-bunny` || unbenched (9 of 29 listed Go models) | the vendor's `-contributor` / `-preview` suffixes and bare family ids have no AA spelling; a per-id alias would be a table, which the ruling forbids |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-MODEL-TIERS.md"

</details>
