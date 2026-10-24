---
id: EP-OPENAI-CHAT
use-cases: [UC-1]
schema: openai-chat.schema.json
---
# POST /openai/v1/chat/completions · GET /openai/v1/models — the OpenAI dialect, on any rail that speaks it

The data-plane path an `opencode` / `goose` harness rides ([UC-1](../use-cases/uc-1-worker-ride.md)
step ③, openai dialect). The per-request steps are the ones
[anthropic-messages.md](anthropic-messages.md) owns — session resolution
([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary)), the model check
([GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve)), the [Go rail](../../../docs/agents/chainless-redesign.md)'s wire
([GW-RAIL-OPENCODE](anthropic-messages.md#gw-rail-opencode)) — applied to this path. This page
owns the **OpenRouter rail**, which serves both dialects, and states the one cell this dialect
cannot serve: the `anthropic` rail (501). Harnesses list models at start, so
`GET /openai/v1/models` is a passthrough on the rails that have one.

## Interface — the machine half

**[`openai-chat.schema.json`](openai-chat.schema.json)** holds the inbound envelope the gateway
inspects, the per-rail upstream contract and the error envelope; the service **imports it**.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-RAIL-OPENROUTER](#gw-rail-openrouter) | `upstream.openrouter` (URL per dialect, auth, the `provider` pin), `models.openrouter`, `output.complete`, `$defs.endpoint_snapshot`, `$defs.providers_block` | `upstream-auth`, `upstream-unreachable`, `upstream-timeout`, `upstream-content-type` | v0 + the provider axis ([§Attribution](#attribution--the-answer-names-the-cell), [§Selection](#selection--the-gateways-own-evidence-never-exacto), [§Failover](#failover--before-the-first-byte-only) — homelab#2741; `:exacto` is NOT ported, operator 2026-10-19); the headroom poll / the `/generation` cost harvest `⚑ gap` (rows below); `upstream-timeout` rows `🚧 WIP` |
| [GW-RAIL-OPENCODE](anthropic-messages.md#gw-rail-opencode) (owned there) | `upstream.opencode`, `models.opencode` | `upstream-auth`, `upstream-unreachable` | linked |
| [GW-RAIL-ANTHROPIC](anthropic-messages.md#gw-rail-anthropic) (owned there) | `upstream.anthropic` (none — 501) | `dialect-unsupported-on-rail` | linked |
| [GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve) (owned there) | `input.body.model` | `model-not-session` | linked |
| [GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary) (owned there) | `input.headers.authorization`, `input.headers.x-api-key` | `session-unknown`, `session-expired`, `session-released`, `credential-unresolved`, `credential-transient`, `upstream-auth`, `upstream-refused`, `upstream-edge-refused`, `header-refused` | linked |
| [GW-SESSIONS-RELEASE](sessions.md#gw-sessions-release) (owned there) | `input.headers.authorization` | `session-expired`, `session-released` | linked |
| [GW-CRED-RESOLVE](sessions.md#gw-cred-resolve) (owned there) | `upstream.*.auth` | `credential-unresolved`, `credential-transient` | linked |

Rows run against the **`policy-default` world**; the canonical pair is
[`uc-1/openrouter-request.json`](../use-cases/uc-1/openrouter-request.json) →
[`openrouter-response.json`](../use-cases/uc-1/openrouter-response.json).

## GW-RAIL-OPENROUTER

The `openrouter` rail is the stack's own OpenRouter key (`OPENROUTER_API_KEY` from
`stacks.<stack>.openrouter_ref`), injected as `Authorization: Bearer <key>`. Openai dialect →
`https://openrouter.ai/api/v1/chat/completions`; models → `https://openrouter.ai/api/v1/models`.
Anthropic dialect → `https://openrouter.ai/api/v1/messages` — **verified 2026-10-15**:
OpenRouter's published `openapi.json` lists `POST /messages` under the server
`https://openrouter.ai/api/v1` ("Creates a message using the Anthropic Messages API format.
Supports text, images, PDFs, tools, and extended thinking."; auth = the global `apiKey`
scheme, i.e. the same bearer); the human docs index and `llms.txt` do not mention it, so the
openapi file is the citation. ⚖ Whether that endpoint honours `anthropic-beta` is not stated
anywhere read — the header is forwarded untouched and the row is **verify during
implementation**. The body's `model` is the bare policy id. Upstream 429 passes through with
`retry-after` (and cools the session's cell — [§Capacity](sessions.md#capacity--the-ladders-capacity-half));
401/403 is 424 `upstream-auth`, 403 `upstream-refused` or 403 `upstream-edge-refused` ([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary)); a connection that fails before any byte is sent
is 502 `upstream-unreachable` (a timeout is 504 `upstream-timeout`). ⚖ The policy keeps the
harness's User-Agent on this rail (`user_agent: forward`). The experiment's inkling rides passed
OpenRouter's "agentic harnesses only" gate as opencode traffic (60 × 200); its one 403 was a bare
smoke call. A fixed UA might fail that gate, while this rail's edge has not refused a caller UA. An
edge refusal here would be request-scoped anyway ([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary)).
A rejected stack key is re-verified with `GET /v1/key` (free).

| description | dialect | inbound header || upstream header |
|---|---|---||---|
| "the stack key rides as a bearer on the openai dialect" | openai | `Authorization: Bearer gws_…` || `Authorization: Bearer <OPENROUTER_API_KEY>` |
| "the stack key rides as a bearer on the anthropic dialect" | anthropic | `x-api-key: gws_…` || `Authorization: Bearer <OPENROUTER_API_KEY>`, no `x-api-key` |
| "anthropic-beta is forwarded untouched ⚖ (verify)" | anthropic | `anthropic-beta: oauth-2025-04-20` || `anthropic-beta: oauth-2025-04-20` |
| "the Go session header is not this rail's business" | openai | `x-opencode-session: <id>` || `x-opencode-session: <id>` (passthrough, meaningless here) |
| "the user agent passes through (`user_agent: forward`) ⚖" | openai | `User-Agent: goose/1.x` || `User-Agent: goose/1.x` |

| description | inbound path | upstream behaviour || upstream URL | status | body | recorded on the session |
|---|---|---||---|---|---|---|
| "an openai-dialect call lands" | `POST /openai/v1/chat/completions` | upstream-ok || `https://openrouter.ai/api/v1/chat/completions` | 200 | byte-identical | `requests` +1, `tokens_in` = `usage.prompt_tokens`, `tokens_out` = `usage.completion_tokens` |
| "an anthropic-dialect call lands" | `POST /anthropic/v1/messages` | upstream-ok || `https://openrouter.ai/api/v1/messages` | 200 | byte-identical | `tokens_in` = `usage.input_tokens`, `tokens_out` = `usage.output_tokens` |
| "the models list passes through" | `GET /openai/v1/models` | upstream-ok || `https://openrouter.ai/api/v1/models` | 200 | byte-identical | nothing |
| "an openai-dialect cache read is split out" | `POST /openai/v1/chat/completions` | upstream-ok-cached || `…/chat/completions` | 200 | byte-identical | (`requests`, `tokens_in`, `tokens_cache_read`, `tokens_cache_write`, `tokens_out`) = (1, 12, 300, 0, 7) — `tokens_in` = `prompt_tokens` − `prompt_tokens_details.cached_tokens` ⚖ |
| "a stream streams" | `POST /openai/v1/chat/completions`, `stream: true` | upstream-stream || `…/chat/completions` | 200 | SSE bytes unchanged | tokens from the last chunk's `usage` when present, else unchanged ⚖ |
| "a rate limit passes through" | `POST /openai/v1/chat/completions` | upstream-429 || `…/chat/completions` | 429 | the upstream body, `retry-after` kept | `requests` +1 |
| "an upstream auth failure is typed and hidden" | `POST /openai/v1/chat/completions` | upstream-401 || `…/chat/completions` | 424 | `upstream-auth` envelope | `requests` +1 |
| "an unreachable upstream is typed" | `POST /openai/v1/chat/completions` | upstream-down || `…/chat/completions` | 502 | `upstream-unreachable` envelope | `requests` +1 |
| "🚧 WIP: a read past 600 s" | `POST /openai/v1/chat/completions` | upstream-slow || `…/chat/completions` | 504 | `upstream-timeout` | `requests` +1 |

Stream completeness on this dialect: the terminal event is `data: [DONE]`; the rule and the four
`incomplete` reasons are [GW-RAIL-ANTHROPIC](anthropic-messages.md#gw-rail-anthropic)'s. The
`upstream-stream-cut` world delivers the status and a first chunk, then fails the read.

| description | upstream behaviour || client sees | recorded on the session | `gateway_requests_incomplete_total{rail="openrouter",dialect="openai",reason}` |
|---|---||---|---|---|
| "a stream that ends without [DONE] is recorded incomplete" | upstream-stream-truncated (stream: true) || 200, the bytes unchanged | `requests_incomplete` 1; the request row's `incomplete` = `no-terminal` | `no-terminal` = 1 |
| "a stream that ends with [DONE] is complete" | upstream-stream (stream: true) || 200 | `requests_incomplete` 0; `incomplete` = null | `no-terminal` = 0 |
| "a non-streamed answer read to its end is complete" | upstream-ok || 200 | `requests_incomplete` 0; `incomplete` = null | `no-terminal` = 0 |
| "a stream cut by a read timeout is recorded incomplete" | upstream-stream-cut (timeout) || 200, then the body breaks | `requests_incomplete` 1; `incomplete` = `timeout`; the row's status 504 | `timeout` = 1 |
| "a stream cut by the transport is recorded incomplete" | upstream-stream-cut (transport-error) || 200, then the body breaks | `requests_incomplete` 1; `incomplete` = `transport-error` | `transport-error` = 1 |

| description | session rail | inbound path || status | body |
|---|---|---||---|---|
| "the subscription cannot speak openai" | anthropic | `POST /openai/v1/chat/completions` || 501 | `dialect-unsupported-on-rail` |
| "the subscription has no models list" | anthropic | `GET /openai/v1/models` || 501 | `dialect-unsupported-on-rail` |
| "the Go rail speaks openai" | opencode | `POST /openai/v1/chat/completions` || 200 | byte-identical ([GW-RAIL-OPENCODE](anthropic-messages.md#gw-rail-opencode)) |

### Attribution — the answer names the cell

*The gateway attributes every openrouter answer to the provider that served it, per request* (operator
ruling 2026-10-19: `:exacto` papered over the old router's inability to attribute provider problems —
not ported). The answer itself says who served it: a chat completion's or a Messages answer's
top-level `provider`, a stream's first data chunk that carries one, an error envelope's
`error.metadata.provider_name` — read by the same bounded pass that reads the terminal usage, no
`/generation` harvest, no after-the-fact join. The value is a DISPLAY name (`DeepInfra`); the cell's
provider key is the endpoint tag's base **slug** (`deepinfra`), what `provider.order` names, joined
through the [endpoint snapshot](#selection--the-gateways-own-evidence-never-exacto)'s `provider_name`.
⚖ A name the snapshot lacks is slugged by RULE (lower-case, runs of non-alphanumerics → `-`), never
a table — so it may differ from the vendor's tag (`OpenInference` → `openinference`, tag
`open-inference`) until the snapshot covers the model. The slug rides on the request row
(`requests.provider`), on the gateway's transport strikes and the consumer's cell-scoped outcomes
([GW-SESSIONS-OUTCOME](sessions.md#gw-sessions-outcome)) and on the 429 cooldown
([GW-SESSIONS-ADMIT §Capacity](sessions.md#capacity--the-ladders-capacity-half)): the cell is
`(rail, model, provider)`, `''` when no answer named one.

World `policy-default · openrouter-endpoints` ([worlds/README.md](../worlds/README.md#the-openrouter-endpoints-world)):
the store holds the snapshot of `deepseek/deepseek-v4.1-flash` (M — the openrouter heavy tier; ten
endpoints trimmed from the live answer of 2026-10-19); `deepseek/deepseek-v4-flash` (M′ — the standard
tier) has no entry and rides unpinned. A worker with harness opencode, `rail: openrouter`.

| description | ride | the answer names || request row `provider` | strike `provider` |
|---|---|---||---|---|
| "a chat completion's provider is the cell" | pinned deepinfra, upstream-ok | `provider: "DeepInfra"` || deepinfra | — |
| "a stream's first chunk names the cell" | pinned deepinfra, upstream-stream | the first chunk's `provider: "DeepInfra"` || deepinfra | — |
| "the snapshot joins the display name to the slug provider.order uses" | pinned inference-net (deepinfra, atlas-cloud, morph struck for the task) | `provider: "InferenceNet"` || inference-net | — |
| "a name the snapshot lacks is slugged by rule ⚖" | unpinned (M′, no snapshot), upstream-ok | `provider: "Sail Research"` || sail-research | — |
| "the rule is not the tag: a snapshot-less name may differ from its slug ⚖" | unpinned (M′), upstream-ok | `provider: "OpenInference"` || openinference (the tag reads `open-inference`) | — |
| "an answer that names no provider is unattributed" | unpinned (M′), upstream-ok, no `provider` || `''` | — |
| "the answer's name outranks the pin ⚖" | pinned deepinfra; the fake answers as AtlasCloud || atlas-cloud (logged) | — |
| "a transport strike carries the provider" | unpinned (M′), upstream-stream-truncated, `provider: "Sail Research"` || sail-research | stream-incomplete @ sail-research |

### Selection — the gateway's own evidence, never `:exacto`

*The gateway selects the provider itself.* Candidates per model come from the **endpoint snapshot**
(`$defs.endpoint_snapshot`: per model, the rows of `GET /api/v1/models/<id>/endpoints` — slug, display
name, quantization, `supports_tool_choice` per mode, `uptime_last_1d`, p90 latency, prices — kept in
the store's `catalog_snapshots` under `openrouter-endpoints`). Who writes it is the catalog leg
(homelab#2742, [GW-CATALOG-GO](catalog.md#gw-catalog-go)'s "the OpenRouter rail's registry" row);
this rule only reads it, and a model the snapshot does not cover rides **unpinned** — attribution
only, the vendor's own routing, exactly as before. The policy's `rails.openrouter.providers` block
(`$defs.providers_block`) holds the floors and the bound; the endpoints are never policy.

⚖ **Eligibility**: one representative endpoint per PROVIDER (`provider.order` names the tag's base
slug, so a provider's service tiers — `deepinfra/fp8`, `/flex`, `/priority` — are one entry; the
representative is the vendor's default: no `service_tier`, then the shortest tag), kept only when it
supports **every tool-choice mode the session's harness uses** (`providers.tool_choice.<harness>`),
its **quantization** is on the policy ladder at or above the floor (`unknown` is off the ladder:
excluded), its **`uptime_last_1d`** clears the floor (⚖ a `null` figure — the vendor's answer for a
fresh or idle endpoint, read live on 2026-10-20 under two models — is parsed as *no uptime* and
clears no floor: the row is kept in the snapshot, dropped by eligibility, never a parse failure that
loses the whole model), and its status is 0. ⚖ **Entry** ([GW-CATALOG-OR](catalog.md#gw-catalog-or)): of the endpoints that pass the floors, only the cells the
catalog has admitted — a clean entry canary, state `eligible` — are pinned; a model with no eligible cell rides
unpinned (the seeded worlds mark every snapshot cell eligible: already canaried). ⚖ **Order**: output price
÷ the cell's **clean-ride rate** from the outcome store (a ride = a session the provider served a 2xx
to whose latest outcome is reported; clean = that outcome is `clean`), the input price, p90 latency
and the slug breaking ties; while a cell has fewer than `min_rides` judged rides, its uptime is the
prior. Struck (for the task) and cooled provider cells are left out. ⚖ **The pin**: ONE provider per
attempt — `provider: {order: [slug], allow_fallbacks: false}` on the body, the harness's other keys
unchanged (the body is re-serialised) — so a failure is attributable; the gateway, not the vendor,
moves to the next ([§Failover](#failover--before-the-first-byte-only)). The anthropic dialect's
`/messages` takes the same block (verify during implementation, as the `anthropic-beta` row).

The snapshot's ten endpoints, representatives by slug (quantization · tool-choice none/auto/required/function · uptime_1d · out $/M):
open-inference fp4 ✓✓✓✓ 100 0.08 · morph fp8 ✓✓✗✗ 99.5 0.60 · inference-net fp8 ✓✓✓✓ 100 0.715 ·
deepinfra fp8 ✓✓✓✓ 100 0.42 (its `/flex` 84.5 and `/priority` tiers beside it) · atlas-cloud fp8 ✓✓✓✓
100 0.54 · alibaba unknown · baidu fp8 ✓✓✗✓ 100 1.20 · parasail fp8 ✗✓✗✗ 77.4 1.20.

| description | harness | arrange || the order (`provider.order[0]` of successive attempts), or the pin |
|---|---|---||---|
| "the floors: ≥ fp8, every tool-choice mode the harness uses, uptime_1d ≥ 95, status 0 ⚖" | opencode | — || deepinfra, atlas-cloud, morph, inference-net, baidu (dropped: open-inference fp4, alibaba unknown, parasail uptime 77.4) |
| "an endpoint with no uptime figure is dropped, the model's other endpoints stand ⚖" | opencode | the snapshot with atlas-cloud/fp8's `uptime_last_1d` `null` || deepinfra, morph, inference-net, baidu (dropped: atlas-cloud `uptime_1d unknown`, and the three above) |
| "a harness that needs required + function drops the providers without them ⚖" | claude (anthropic dialect) | — || deepinfra, atlas-cloud, inference-net (morph, baidu dropped) |
| "the pin is one provider with fallbacks off ⚖" | opencode | — || upstream body `provider = {order: [deepinfra], allow_fallbacks: false}`; model and messages unchanged |
| "a provider's service tiers are one order entry: the default tag represents ⚖" | opencode | deepinfra/fp8, /flex (uptime 84.5), /priority in the snapshot || the deepinfra entry is `deepinfra/fp8` (out $0.42/M) |
| "the order is price ÷ the cell's clean-ride rate ⚖" | opencode | 5 judged rides on deepinfra, 2 clean (rate 0.4: 0.42 ÷ 0.4 = 1.05) || atlas-cloud first (0.54), deepinfra 4th (before baidu's 1.2) |
| "under min_rides the uptime is the prior ⚖" | opencode | 4 judged rides on deepinfra, 0 clean || deepinfra still first (prior: uptime 100) |
| "a struck provider cell is left out for the task" | opencode | the task's earlier ride struck `harness-gave-up` on deepinfra || atlas-cloud first; another task still pins deepinfra |
| "a cooled provider cell is left out" | opencode | deepinfra answered 429 (retry-after 30) on the previous request || atlas-cloud first; +30 s deepinfra again |
| "no snapshot for the model: the request rides unpinned ⚖" | opencode (M′) | — || the upstream body carries no `provider` key |

### Failover — before the first byte only

*A failed provider is relaunched transparently, at the REQUEST level* (operator ruling 2026-10-19 —
never at the ride level). A typed transport failure of a PINNED attempt **before any byte has been
relayed** — an upstream 5xx, a 429 on that endpoint, a connect failure or timeout, a 2xx whose body
is not one the dialect reads (`content-type` neither JSON nor SSE: an edge's page behind a 200), or a
4xx whose JSON error names the provider that produced it (`error.metadata.provider_name` — OpenRouter's
wrap of the provider's own refusal, a refused tool call among them) — strikes that `(model, provider)`
cell (`provider-5xx` / `timeout` / `refused`; a 429 cools the cell instead) and **reissues the same
request to the next provider in the order**, silently to the harness, ⚖ bounded by
`providers.max_providers_per_request` (one pin + the failovers). Every attempt is a request row with its
provider and status, and counts on `gateway_provider_requests_total{rail,model,provider,outcome}`; a
move counts on `gateway_provider_failovers_total{model,from,to}` ([GW-METRICS](metrics.md#gw-metrics)).
**After a byte has been relayed: never** — the stream-completeness outcome stands (the same line the
codex rail draws). The order exhausted → the last attempt's answer is the typed outcome: a relayed
5xx / 429 / 4xx, 502 `upstream-unreachable`, 504 `upstream-timeout`, or 502 `upstream-content-type` for
an unreadable 2xx. ⚖ A request whose every eligible provider is cooled or struck mid-session rides
unpinned rather than failing the ride.

| description | provider_behaviours || upstream calls (pins, in order) | status | the harness sees | strikes (class @ provider) | `gateway_provider_failovers_total{model=M,from,to}` |
|---|---||---|---|---|---|---|
| "fails over once" | deepinfra: upstream-500 || deepinfra, atlas-cloud | 200 | one JSON answer, served by AtlasCloud | provider-5xx @ deepinfra | deepinfra→atlas-cloud 1 |
| "fails over twice" | deepinfra: upstream-500, atlas-cloud: upstream-html || deepinfra, atlas-cloud, morph | 200 | served by Morph | provider-5xx @ deepinfra, provider-5xx @ atlas-cloud | deepinfra→atlas-cloud 1, atlas-cloud→morph 1 |
| "exhausts the order: the last answer is the typed error, bounded by max_providers_per_request 3 ⚖" | deepinfra, atlas-cloud, morph: upstream-500 || deepinfra, atlas-cloud, morph (inference-net never asked) | 500 | the last provider's 500 body | provider-5xx @ deepinfra, @ atlas-cloud, @ morph | 2 series, 1 each |
| "a 429 fails over and cools only that provider's cell ⚖" | deepinfra: upstream-429 || deepinfra, atlas-cloud | 200 | served by AtlasCloud | none (a 429 is a cooldown) | deepinfra→atlas-cloud 1 |
| "the cooled provider's model still admits ⚖" | deepinfra: upstream-429 || deepinfra, atlas-cloud | 200 | served by AtlasCloud | none | `gateway_cells_cooled{rail=openrouter}` 1; `POST /sessions` worker, `rail: openrouter`, `tier: heavy` → dispatch M |
| "a provider's own refusal (a 4xx naming it) fails over ⚖" | deepinfra: upstream-provider-400 || deepinfra, atlas-cloud | 200 | served by AtlasCloud | refused @ deepinfra | deepinfra→atlas-cloud 1 |
| "a 2xx the dialect cannot read is a pre-byte failure ⚖" | deepinfra: upstream-html || deepinfra, atlas-cloud | 200 | served by AtlasCloud | provider-5xx @ deepinfra | deepinfra→atlas-cloud 1 |
| "a post-byte failure never fails over" | deepinfra: upstream-stream-truncated || deepinfra | 200, incomplete (no-terminal) | the cut stream | stream-incomplete @ deepinfra | none |
| "every provider cooled or struck mid-session: the request rides unpinned ⚖" | the five eligible cells cooled by 429s || the next request carries no `provider` key | 200 | served (the lottery) | — | — |

### Named gaps

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: key headroom" | the stack key at its limit || dispatched, upstream answers 402/429 | the FU-088 headroom poll (`/api/v1/auth/key`) |
| "⚑ gap: cost per request" | upstream-ok || tokens only, no USD | the `/generation` harvest and the cost ledger |
| "⚑ gap: the [Zen rail](../../../docs/spikes/opencode-model-matrix.md)" | `rail: zen` || 400 `malformed-body` (not in the enum) | `opencode-zen` is declared `enabled: false` upstream; not a v0 rail |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-RAIL-OPENROUTER.md"

</details>
