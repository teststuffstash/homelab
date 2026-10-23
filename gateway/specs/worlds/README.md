# worlds/ — named fixture states

A **world** is a named, human-readable fixture state: expected behaviour is a function of
(system, world), so a row that does not name its world is lying by omission. For the gateway a
world has two halves — a **policy document** and an **upstream behaviour** — and a row names
both when a requirement's evidence spans more than one of either (`"policy-default · upstream-429: …"`);
a single-world module declares it once in its docstring and omits it from row ids.

## Policy worlds

| world | file | what it is |
|---|---|---|
| `policy-default` | [policy-default.json](policy-default.json) | the test policy (plan `go` on the opencode rail — [GW-CATALOG-GO](../endpoints/catalog.md#gw-catalog-go)): two stacks (`platform`, `oracle`), all seven roles, three rails with the model ids copied from `model-classes.json` (the opencode rail's from the world's Go catalog — below) — two tiers name ordered LISTS (anthropic heavy `[claude/sonnet, claude/opus]`, openrouter light `[deepseek/deepseek-v4-flash, deepseek/deepseek-v4.1-flash]`, the `coding` chain_head order), the rest bare strings; caps small enough to fill in a test (`anthropic` 5, `opencode` 3, `openrouter` 20); the anthropic rail's `side_models` = `claude/haiku` (claude-code's side-call family, [GW-MODEL-RESOLVE](../endpoints/anthropic-messages.md#gw-model-resolve) ⚖); `control_plane_auth: observe` with three fixture `callers` (the platform loop, the specs reviewer — [GW-SESSIONS-AUTH](../endpoints/sessions.md#gw-sessions-auth) — and a judge, `outcome: any`, [GW-SESSIONS-OUTCOME](../endpoints/sessions.md#gw-sessions-outcome)), so a row that sends no caller token is admitted; `outcome_window_s` 86400; the per-rail header and recovery keys: `user_agent` (`forward` on anthropic and openrouter, `fixed` on opencode) and `credential_probe` (opencode: `POST /v1/chat/completions`, 1 token on its light model; openrouter: `GET /v1/key`; anthropic none, so `credential_hold_s` defaults to 900) — [§Capacity](../endpoints/sessions.md#capacity--the-ladders-capacity-half) |
| `policy-enforce` | [policy-enforce.json](policy-enforce.json) | `policy-default` with `control_plane_auth: enforce` and nothing else changed — for the GW-SESSIONS-AUTH enforce rows only |
| `policy-codex` | [policy-codex.json](policy-codex.json) | `policy-default` plus the codex rail (`max_sessions` 2, the fixture model `codex/fixture-model`, `headroom` 120 s / 0.95 / the 300- and 10080-minute windows, `oauth.refresh_margin_s` 30), its roles shaped as the 2026-10-23 ruling (every role lists `anthropic`, `opencode` and `codex`; `prober` = `anthropic`, `codex`) — the codex rows and the GW-SESSIONS-ADMIT §The harness follows the rail rows; the deployed policy's lists are its own |

Names in the test policy (namespaces, Secret names) are **fixture names**, not production
ones; the production policy is the ConfigMap in `argocd/resources/agent-gateway/`. Model ids
are the exception: they are copied verbatim from
`argocd/resources/openrouter-proxy/model-classes.json` (`models.*.ids` per rail, the `coding`
class's `chain_head` order) so the fixture never names a model the fleet does not run. The
exceptions to the exception: `policy-codex`'s `codex/fixture-model` — the fleet runs no codex model
yet, and choosing a representative one is the design session's call, not a fixture's ⚖ — and the
**opencode rail's** ids, which are ids the world's Go catalog lists (the deployed policy's Go ids
are checked against the vendor's catalog too, not `model-classes.json` — #2694):
`opencode-go/deepseek-v4.1-flash` (light, standard — the deployed choice) and
`opencode-go/claude-haiku-5-5` (heavy), so the tier rows and the claude-on-Go rows stay
distinguishable ⚖.

Every policy world also carries the `tiers` block of the deployed policy (`score: intelligence`,
bands 0.9 / 0.75 / 0.5, cap 3 — [GW-MODEL-TIERS](../endpoints/catalog.md#gw-model-tiers)) so one
loader shape holds everywhere, but its LISTS stay the fixture ids above: the derivation applies to
the deployed policy only ⚖.

## Upstream behaviours (fake upstreams)

Each rail's upstream is an in-process fake mounted per test — offline, deterministic, no network.
A behaviour is what the fake does with the next request; tests assert on the **request the fake
received** (URL, headers, body) as much as on the response the gateway returned.

| behaviour | the fake answers | exercised by |
|---|---|---|
| `upstream-ok` | 200, a complete JSON body with `usage` (`input_tokens`/`output_tokens` on the anthropic dialect, `prompt_tokens`/`completion_tokens` on openai); on the `anthropic` rail every answer also carries the live `anthropic-ratelimit-unified-{5h,7d}-{status,utilization,reset}` set (5h 0.13, 7d 0.67, captured 2026-10-16) | the happy rows on every rail; usage accounting; the subscription-window gauges |
| `upstream-ok-cached` | `upstream-ok` with a cache split: anthropic `usage {input_tokens: 12, cache_read_input_tokens: 300, cache_creation_input_tokens: 40, output_tokens: 7}`; openai `usage {prompt_tokens: 312, completion_tokens: 7, prompt_tokens_details: {cached_tokens: 300}}` | the four token classes; the openai-dialect normalisation |
| `upstream-ok-usage` | `upstream-ok` whose anthropic-dialect `usage` is the row's (`FakeUpstream.usage`); on the anthropic rail `FakeUpstream.rate_headers` likewise replaces the `anthropic-ratelimit-unified-*` set with the row's reading | the capacity rows (window utilization, Go window draw) |
| `upstream-stream` | 200, `text/event-stream`, a final usage event (anthropic: `message_delta` with `usage`; openai: a last chunk with `usage`) | byte-unchanged SSE passthrough; streaming usage best-effort |
| `upstream-stream-gzip` | `upstream-stream`'s anthropic events, `content-encoding: gzip`, flushed per event — the live shape (2026-10-16) | usage parsed from the decoded capture while the bytes pass through encoded |
| `upstream-429` | 429 with `retry-after: 30` | 429 passthrough with `retry-after`; the subscription latch rows |
| `upstream-429-no-header` | 429 with no reset header at all | the hold / `defer_retry_s` fallbacks |
| `upstream-429-shared-pool` | OpenRouter's shared-pool 429 (the 2026-10-22 tap on `kimi-k3@baseten`, homelab#2775): `retry-after: 30`, body `{error: {message: "Provider returned error", code: 429, metadata: {raw, provider_name, is_byok: false, limit_source: upstream_provider_shared_pool, retry_after_seconds: 30, …}}}` — the PINNED provider throttles OpenRouter's shared upstream account; a per-provider behaviour | the 429'd-canary rows ([GW-CATALOG-OR §The entry canary](../endpoints/catalog.md#the-entry-canary)) |
| `upstream-429-reset` | OpenRouter's 429 shape (the 2026-10-17 tap): `x-ratelimit-limit: 20`, `-remaining: 0`, `-reset` = the row's epoch **milliseconds**, no `retry-after` (a row may add one), body `limit_source: openrouter_free_tier_per_minute` | the cell-cooldown rows ([§Capacity](../endpoints/sessions.md#capacity--the-ladders-capacity-half)) |
| `upstream-401` | 401 with a body mentioning the key | 424 `upstream-auth`, body never forwarded; the credential rejected |
| `upstream-401-key-expired` | 401 `{type: authentication_error, code: api_key_expired}` — the Go vendor's live answer to an expired key (the 2026-10-17 tap) | 424 `upstream-auth` on the opencode rail |
| `upstream-500` | 500 `{error: {message, code: 500, metadata: {provider_name}}}` — OpenRouter's wrap of a provider's 5xx (the `metadata.provider_name` names the pinned provider when the request carried a pin) | the relayed-5xx rows; the failover rows |
| `upstream-html` | 200 `text/html` (an edge's page behind a 200 — not a body the dialect reads) | the `content-type` failover rows (GW-RAIL-OPENROUTER §Failover) |
| `upstream-provider-400` | 400 `{error: {message: "Provider returned error", code: 400, metadata: {raw, provider_name}}}` — OpenRouter's wrap of the PROVIDER's own refusal (a tool call it cannot serve) | the `provider-error` failover row |
| per-provider behaviours (`FakeUpstream.provider_behaviours[slug]`) | a request PINNED to `slug` (`provider.order[0]`) is answered as that slug's behaviour says, every other request as the fake's `behaviour`; every 200 of a pinned request names the serving provider (`provider_names[slug]`, the snapshot's display name) at the top level / in the first SSE chunk; an unpinned 200 names `provider_display` (None = unnamed) | the openrouter-endpoints world below |
| `upstream-403` | 403 `{type: permission_error}` — a credential reason | 424 `upstream-auth` |
| `upstream-403-edge` | 403 `text/plain` `error code: 1010` — Cloudflare's client-signature refusal (the 2026-10-17 self-latch) | 403 `upstream-edge-refused`; nothing marked |
| `upstream-403-html` | 403 with an HTML block page (what opencode.ai's edge answered `Python-urllib`, probed live 2026-10-17) | 403 `upstream-edge-refused`; nothing marked |
| `upstream-403-refused` | 403 with OpenRouter's harness-gate body (`… only available on agentic harnesses`, `failed_routing_step`) — no credential reason | 403 `upstream-refused`; the credential untouched |
| `upstream-slow` | holds the response past the read timeout | timeout rows (connect 10 s / read 600 s) — 🚧 WIP, clock-faked only |
| `upstream-down` | the connection fails before any byte is sent (refused / DNS / reset — not a timeout) | 502 `upstream-unreachable` rows on every rail |
| `upstream-stream-truncated` | `upstream-stream` cut after its first event: no usage, no terminal event (`data: [DONE]` / `message_stop`) | the stream-completeness rows (`no-terminal`) |
| `upstream-stream-cut` | the status and a first chunk arrive, then the read fails (`RailTransport.cut[rail]` = `timeout` → `ReadTimeout`, `transport-error` → `RemoteProtocolError`) | the `timeout` / `transport-error` completeness rows |

## The codex rail's fakes (`tests/_codex_world.py`)

The codex upstream is a fake `POST /responses` whose behaviours are the stream shapes of
[GW-RAIL-CODEX](../endpoints/openai-responses.md#gw-rail-codex): `upstream-ok` (the native CLI's
accepted shape, usage 7 in / 3 out), `upstream-ok-cached` (312 in incl. 300 cached, 7 out),
`upstream-stream-{failed,incomplete,truncated,invalid,duplicate}`, `upstream-{401,403,429,500,302}`,
`upstream-wrong-type`; `upstream-down` / `upstream-slow` ride the shared transport. The credential
is held by **`MemoryStore`**, the FAKE persistence backend (process memory, injectable save
failures) with dummy `DUMMY-SECRET-…` values; a counting fake `exchange` returns the rotation.
`native-refresh` (`tests/test_codex_refresh.py`) replaces the counting exchange with the native
HTTP adapter and a MockTransport endpoint: fabricated JWTs, rotation/rejection responses and
request capture. No network or vendor account is involved.
Headroom reports enter through the in-process seam (`app.state.codex.headroom.observe`).

## The Go catalog's fakes

`tests/_catalog_world.py`'s `FakeVendor` answers the three reads of
[GW-CATALOG-GO](../endpoints/catalog.md#gw-catalog-go) in process, on fixture hosts
(`models.dev.test`, `console.opencode.test`, `raw.vendor.test`). `tests/fixtures/go-catalog/models-dev.json`
is models.dev's `api.json` cut to the `opencode-go` provider and six of its models — the five
listed (`claude-haiku-5-5`, `deepseek-v4-pro`, `deepseek-v4.1-flash`, `longcat-2.5-preview-free`,
`step-5-preview`) plus `step-5-preview-free`, a live `status: deprecated` row — from the **live
answer of 2026-10-20**. `tests/fixtures/go-catalog/config.json` is `GET /console/api/v2/config` as
the same day's live answer carries it: the workspace's OVERRIDES on a default catalog (the
pay-as-you-go `opencode` provider's `disabled: true` rows, cut to five; `opencode-go` with
`models: {}`), the account's org-id header dropped — every `config-*` variant adds one override to
the Go provider in memory. `tests/fixtures/go-catalog/go.mdx` is the vendor's page cut to its Plan table (the two plans'
monthly fees, verbatim from the live page of 2026-10-20 — the [Go price](../glossary.md#go-price)
divides the policy plan's), its Usage-limits section and Endpoints table for the same five
models, rows otherwise verbatim. Every variant below is derived
from those two files in memory. **Every world's gateway starts from this catalog**:
`conftest.seed_go_catalog` stores the `catalog-ok` + `config-ok` (merged) and `docs-ok` snapshots
(parsed by the leg's own parsers, fetched at T0) before the gateway is built, as a production gateway starts from its
persisted last good snapshot — so the opencode rail's admission rows price from it. A row that
needs another catalog refreshes against the fake vendor first (`catalog-retired`, `docs-retired`).

| behaviour | the fake answers |
|---|---|
| `catalog-ok` | 200, the models.dev fixture (six rows, one deprecated) |
| `catalog-trimmed` / `catalog-shrunk` | the fixture with 3 (`claude-haiku-5-5`, `deepseek-v4-pro`, `deepseek-v4.1-flash`) / 2 (`deepseek-v4-pro`, `deepseek-v4.1-flash`) models |
| `catalog-retired` | the fixture without `deepseek-v4.1-flash` (the policy's model leaves the catalog — the spike's §F3, replayed) |
| `catalog-malformed` | the fixture with `deepseek-v4-pro`'s `cost` removed |
| `catalog-legacy-tier` | `deepseek-v4-pro`'s cost carrying `context_over_200k` with no `tiers` (the legacy spelling alone) |
| `catalog-no-provider` | the fixture's provider under the key `opencode` instead of `opencode-go` |
| `catalog-empty` | the fixture with `models: {}` |
| `catalog-503` / `catalog-down` | 503 / a connect failure on the models.dev read |
| `config-ok` | 200, the console fixture — overrides only, `opencode-go.models: {}` |
| `config-disables` | + `deepseek-v4-pro: {disabled: true}` |
| `config-reprices` | + `claude-haiku-5-5` with two `cost` rows (0.20/1.00, above 200000 tokens 1.00/5.00) and `limit.context` 200000 |
| `config-adds` / `config-adds-bare` | + `deepseek-v4-flash` (no catalog row) as a full row (cost, both limits, family, tools) / as `{disabled: false}` alone |
| `config-malformed` | + `deepseek-v4-pro: {cost: "free"}` |
| `config-no-provider` | the console answer without its `opencode-go` provider |
| `config-503` / `config-down` | 503 / a connect failure on the console read |
| `config-401-echo` | 401 whose body names the test Go key (the redaction row) |
| `docs-ok` | 200, the page fixture |
| `docs-404` | 404 (the page moved) |
| `docs-unknown-model` | a `DeepSeek V4.2 Flash` plan row the Endpoints table does not name |
| `docs-short-endpoint-row` | the Endpoints table's `Step 5 Preview` row cut to one cell |
| `docs-header-drift` | the plan tables' `Monthly limit` column renamed `Limit` |
| `docs-no-peak-hours` / `docs-no-shares` | the peak-hours sentence / the 5-hour-weekly-monthly share sentence removed |
| `docs-no-plan-table` | the Plan table (the fee's home) removed |
| `docs-shrunk` | only the two DeepSeek models' rows |
| `docs-retired` | the page without `claude-haiku-5-5`'s plan rows (still listed by the console: no monthly limit) |

## The openrouter-endpoints world

The openrouter rail's provider axis ([GW-RAIL-OPENROUTER §Selection](../endpoints/openai-chat.md#selection--the-gateways-own-evidence-never-exacto),
homelab#2741) reads the [endpoint snapshot](../glossary.md#endpoint-snapshot) from the store.
`conftest.seed_openrouter_endpoints` stores it the way the catalog leg (homelab#2742) will: the raw
`GET /api/v1/models/<id>/endpoints` fixture in `tests/fixtures/openrouter-endpoints/`, parsed by the
leg's own `parse_endpoints`. The one fixture, `deepseek-v4.1-flash.json`, is the live answer of
**2026-10-19** trimmed to ten of its 34 endpoints — every case the floors distinguish:

| tag (slug) | quantization | tool_choice none/auto/required/function | uptime_1d | out $/M | why it is in the fixture |
|---|---|---|---|---|---|
| `open-inference/fp4` | fp4 | ✓✓✓✓ | 100 | 0.08 | the headline price: cheapest, excluded by the fp8 floor |
| `morph/fp8` | fp8 | ✓✓✗✗ | 99.5 | 0.60 | eligible for a harness that uses `auto` only; dropped for claude |
| `inference-net/fp8` | fp8 | ✓✓✓✓ | 100 | 0.715 | eligible, 4th by price |
| `deepinfra/fp8/flex` · `deepinfra/fp8` · `deepinfra/fp8/priority` | fp8 | ✓✓✓✓ | 84.5 · 100 · 100 | 0.336 · 0.42 · 0.63 | three service tiers of ONE provider: `provider.order` names `deepinfra`, the no-tier row represents |
| `atlas-cloud/fp8` | fp8 | ✓✓✓✓ | 100 | 0.54 | eligible, 2nd by price — the failover target |
| `alibaba` | unknown | ✓✓✓✓ | 100 | 0.66 | excluded: `unknown` is off the ladder |
| `baidu/fp8` | fp8 | ✓✓✗✓ | 100 | 1.20 | eligible for `auto`; dropped for claude (no `required`) |
| `parasail/fp8` | fp8 | ✗✓✗✗ | 77.4 | 1.20 | excluded by the uptime floor |

Unless a row seeds it, a world's store holds NO endpoint snapshot (every openrouter request rides
unpinned, as before this leg); `deepseek/deepseek-v4-flash` never has an entry, so the standard
tier is the unpinned control inside the world. `openrouter-endpoints-ineligible` = the same
snapshot trimmed to `open-inference/fp4`, `alibaba` and `parasail/fp8` (`seed_openrouter_endpoints(only=…)`).

## The openrouter-catalog world

[GW-CATALOG-OR](../endpoints/catalog.md#gw-catalog-or)'s sources, faked in process
(`tests/_orcatalog_world.py`): the OpenRouter MCP on `mcp.openrouter.test/mcp` (JSON-RPC
`initialize` + `tools/call`), and the endpoints route on the openrouter rail's fake
(`/v1/models/<id>/endpoints`). Fixtures in `tests/fixtures/openrouter-catalog/`, trimmed from the
**live MCP answers of 2026-10-19**: `rankings-programming.json` / `rankings-tool_calling.json`
(`list-daily-model-rankings`, period week — the latest week's top rows of each slice, 14 and 12
dated permaslugs plus `other`, and one older-week row), `benchmarks-aa.json` (`list-benchmarks`,
source artificial-analysis — seven of the 350 rows: the models the two slices rank that AA
benches), `deepseek-v4.1-flash.json` (the ten-endpoint fixture of the openrouter-endpoints world)
and `glm-5.3-flash.json` (seven of `z-ai/glm-5.3-flash`'s 34 endpoints). Ranked ∩ benched = seven
candidates; two have endpoint fixtures, the other five 404 (unreadable, absent from the refresh).
Unlike the openrouter-endpoints world, nothing is seeded: a refresh (`app.state.orcatalog.refresh()`)
builds the snapshot, and every cell enters as `candidate`.

| behaviour | the fake answers | exercised by |
|---|---|---|
| `mcp` ok | the fixtures per tool and slice | the refresh rows |
| `mcp` 503 / down | 503 / a connect failure on the MCP host | fetch-failed |
| `mcp` malformed | a tool result whose text is not JSON | parse-failed |
| `rankings-undated` | ranking rows without `date` | parse-failed |
| `benchmarks-empty` | an empty AA list | implausible (no candidate) |
| `endpoints_behaviour[model]` = `endpoints-503` / `endpoints-malformed` | 503 / a row without the fields the parser reads, for that model | the unreadable-candidate rows |
| `endpoints_behaviour[model]` = `endpoints-null-uptime` | the fixture with its first endpoint's `uptime_last_1d` set to `null` (what the vendor answers for a fresh or idle endpoint — read live 2026-10-20 under `anthropic/claude-opus-5`) | the no-uptime row |
| `endpoints_behaviour[model]` = `endpoints-null-uptime@<tag>` | the same, on the endpoint whose `tag` is named (`endpoints-null-uptime@inference-net/fp8`: the one M endpoint every harness could otherwise pin) | the floors-verdict rows (`pinnable` / `floor`) |

## The fake TokenReview (`StaticTokenReviews`)

The kube TokenReview API is a seam (`TokenReviewer` protocol). `StaticTokenReviews` maps a
presented token to the review status the API would answer (authenticated, username, audiences,
the pod-name extra); any other token reviews as unauthenticated, and `transient` makes every
review raise. One fake serves both readers of a projected token: the env pull
([GW-SESSIONS-PULL](../endpoints/sessions.md#gw-sessions-pull)) and the control plane's caller
([GW-SESSIONS-AUTH](../endpoints/sessions.md#gw-sessions-auth)). Fixture tokens are plain
`fake-…` strings, never JWT-shaped (the one JWT-shaped literal is GW-REDACT's masking row).

## The credential source (`FakeSecrets`)

The kube API is a seam (`CredentialSource` protocol). `FakeSecrets` holds `namespace/name →
{labels, data}` and can be told to answer any ref with a definitive miss (404/403), an
unlabeled Secret, or a transient fault (5xx / unreachable) — the three verdict classes of
[GW-CRED-RESOLVE](../endpoints/sessions.md#gw-cred-resolve). Values in fixtures are
obviously-fake strings that still match the redaction patterns (`sk-ant-oat-FAKE…`,
`sk-or-v1-FAKE…`) so [GW-REDACT](../endpoints/sessions.md#gw-redact) rows have something to catch.
