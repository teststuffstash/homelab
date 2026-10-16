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
| [GW-RAIL-OPENROUTER](#gw-rail-openrouter) | `upstream.openrouter` (URL per dialect, auth), `models.openrouter` | `upstream-auth`, `upstream-unreachable`, `upstream-timeout` | v0 — provider pins / `:exacto` / the headroom poll / the `/generation` cost harvest `⚑ gap` (rows below); `upstream-timeout` rows `🚧 WIP` |
| [GW-RAIL-OPENCODE](anthropic-messages.md#gw-rail-opencode) (owned there) | `upstream.opencode`, `models.opencode` | `upstream-auth`, `upstream-unreachable` | linked |
| [GW-RAIL-ANTHROPIC](anthropic-messages.md#gw-rail-anthropic) (owned there) | `upstream.anthropic` (none — 501) | `dialect-unsupported-on-rail` | linked |
| [GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve) (owned there) | `input.body.model` | `model-not-session` | linked |
| [GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary) (owned there) | `input.headers.authorization`, `input.headers.x-api-key` | `session-unknown`, `session-expired`, `session-released`, `credential-unresolved`, `credential-transient`, `upstream-auth`, `header-refused` | linked |
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
`retry-after`; 401/403 is 502 `upstream-auth`; a connection that fails before any byte is sent
is 502 `upstream-unreachable` (a timeout is 504 `upstream-timeout`).

| description | dialect | inbound header || upstream header |
|---|---|---||---|
| "the stack key rides as a bearer on the openai dialect" | openai | `Authorization: Bearer gws_…` || `Authorization: Bearer <OPENROUTER_API_KEY>` |
| "the stack key rides as a bearer on the anthropic dialect" | anthropic | `x-api-key: gws_…` || `Authorization: Bearer <OPENROUTER_API_KEY>`, no `x-api-key` |
| "anthropic-beta is forwarded untouched ⚖ (verify)" | anthropic | `anthropic-beta: oauth-2025-04-20` || `anthropic-beta: oauth-2025-04-20` |
| "the Go session header is not this rail's business" | openai | `x-opencode-session: <id>` || `x-opencode-session: <id>` (passthrough, meaningless here) |
| "the user agent passes through" | openai | `User-Agent: goose/1.x` || `User-Agent: goose/1.x` |

| description | inbound path | upstream behaviour || upstream URL | status | body | recorded on the session |
|---|---|---||---|---|---|---|
| "an openai-dialect call lands" | `POST /openai/v1/chat/completions` | upstream-ok || `https://openrouter.ai/api/v1/chat/completions` | 200 | byte-identical | `requests` +1, `tokens_in` = `usage.prompt_tokens`, `tokens_out` = `usage.completion_tokens` |
| "an anthropic-dialect call lands" | `POST /anthropic/v1/messages` | upstream-ok || `https://openrouter.ai/api/v1/messages` | 200 | byte-identical | `tokens_in` = `usage.input_tokens`, `tokens_out` = `usage.output_tokens` |
| "the models list passes through" | `GET /openai/v1/models` | upstream-ok || `https://openrouter.ai/api/v1/models` | 200 | byte-identical | nothing |
| "an openai-dialect cache read is split out" | `POST /openai/v1/chat/completions` | upstream-ok-cached || `…/chat/completions` | 200 | byte-identical | (`requests`, `tokens_in`, `tokens_cache_read`, `tokens_cache_write`, `tokens_out`) = (1, 12, 300, 0, 7) — `tokens_in` = `prompt_tokens` − `prompt_tokens_details.cached_tokens` ⚖ |
| "a stream streams" | `POST /openai/v1/chat/completions`, `stream: true` | upstream-stream || `…/chat/completions` | 200 | SSE bytes unchanged | tokens from the last chunk's `usage` when present, else unchanged ⚖ |
| "a rate limit passes through" | `POST /openai/v1/chat/completions` | upstream-429 || `…/chat/completions` | 429 | the upstream body, `retry-after` kept | `requests` +1 |
| "an upstream auth failure is typed and hidden" | `POST /openai/v1/chat/completions` | upstream-401 || `…/chat/completions` | 502 | `upstream-auth` envelope | `requests` +1 |
| "an unreachable upstream is typed" | `POST /openai/v1/chat/completions` | upstream-down || `…/chat/completions` | 502 | `upstream-unreachable` envelope | `requests` +1 |
| "🚧 WIP: a read past 600 s" | `POST /openai/v1/chat/completions` | upstream-slow || `…/chat/completions` | 504 | `upstream-timeout` | `requests` +1 |

| description | session rail | inbound path || status | body |
|---|---|---||---|---|
| "the subscription cannot speak openai" | anthropic | `POST /openai/v1/chat/completions` || 501 | `dialect-unsupported-on-rail` |
| "the subscription has no models list" | anthropic | `GET /openai/v1/models` || 501 | `dialect-unsupported-on-rail` |
| "the Go rail speaks openai" | opencode | `POST /openai/v1/chat/completions` || 200 | byte-identical ([GW-RAIL-OPENCODE](anthropic-messages.md#gw-rail-opencode)) |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: provider pin / `:exacto` on the body" | openrouter session, upstream-ok || the body carries no `provider` block and no suffix | ADR-096 M4 pin injection, `provider_policy: exacto` |
| "⚑ gap: key headroom" | the stack key at its limit || dispatched, upstream answers 402/429 | the FU-088 headroom poll (`/api/v1/auth/key`) |
| "⚑ gap: cost per request" | upstream-ok || tokens only, no USD | the `/generation` harvest and the cost ledger |
| "⚑ gap: the [Zen rail](../../../docs/spikes/opencode-model-matrix.md)" | `rail: zen` || 400 `malformed-body` (not in the enum) | `opencode-zen` is declared `enabled: false` upstream; not a v0 rail |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-RAIL-OPENROUTER.md"

</details>
