---
id: EP-ANTHROPIC-MESSAGES
use-cases: [UC-1]
schema: anthropic-messages.schema.json
---
# POST /anthropic/v1/messages — the Anthropic Messages dialect, on any rail that speaks it

The data-plane path a `claude` harness rides ([UC-1](../use-cases/uc-1-worker-ride.md) step ③,
anthropic dialect). Per request: the session token is resolved to a session
([GW-CRED-BOUNDARY](#gw-cred-boundary)); the body's `model` is checked against the session's
model ([GW-MODEL-RESOLVE](#gw-model-resolve)); the session's rail decides the upstream URL,
the credential and the header rewrites ([GW-RAIL-ANTHROPIC](#gw-rail-anthropic),
[GW-RAIL-OPENCODE](#gw-rail-opencode), [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter));
the upstream response streams back **byte-unchanged** (SSE included); usage is recorded on the
session best-effort. This page owns the four requirements below; the OpenRouter rail's rows
live on [openai-chat.md](openai-chat.md) and are linked from the coupling table.

## Interface — the machine half

**[`anthropic-messages.schema.json`](anthropic-messages.schema.json)** holds the inbound
envelope the gateway inspects (`model`, `stream`, the auth and session headers), the response
contract (passthrough) and the error envelope; the service **imports it**. The Anthropic
Messages body itself is the vendor's — the gateway validates only what it reads.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-RAIL-ANTHROPIC](#gw-rail-anthropic) | `upstream.anthropic` (URL, auth, `anthropic-beta`) | `upstream-auth`, `upstream-timeout` | v0 |
| [GW-RAIL-OPENCODE](#gw-rail-opencode) | `upstream.opencode` (URL, auth, session headers), `input.headers.x-opencode-session`, `input.headers.x-claude-code-session-id` | `upstream-auth`, `upstream-timeout` | v0; `upstream-timeout` rows `🚧 WIP` (the `upstream-slow` world is clock-faked only) |
| [GW-MODEL-RESOLVE](#gw-model-resolve) | `input.body.model` | `model-not-session` | v0 — provider pins / `:exacto` / the ADR-096 ladder `⚑ gap` (rows below) |
| [GW-CRED-BOUNDARY](#gw-cred-boundary) | `input.headers.authorization`, `input.headers.x-api-key`, `upstream.*.auth` | `session-unknown`, `session-expired`, `session-released`, `credential-unresolved`, `credential-transient`, `upstream-auth` | v0 |
| [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter) (owned on openai-chat.md) | `upstream.openrouter` | `upstream-auth` | linked — the anthropic-dialect cell is a verified row there |
| [GW-SESSIONS-RELEASE](sessions.md#gw-sessions-release) (owned on sessions.md) | `input.headers.authorization` | `session-expired`, `session-released` | linked |
| [GW-CRED-RESOLVE](sessions.md#gw-cred-resolve) (owned on sessions.md) | `upstream.*.auth` | `credential-unresolved`, `credential-transient` | linked |

Rows run against the **`policy-default` world** with the fake upstream in the behaviour each
row names ([worlds/README.md](../worlds/README.md)); the canonical pairs are
[`uc-1/anthropic-request.json`](../use-cases/uc-1/anthropic-request.json) →
[`anthropic-response.json`](../use-cases/uc-1/anthropic-response.json) and the opencode pair
beside them. "Session S on rail R" means a session the test dispatched on that rail.

## GW-RAIL-ANTHROPIC

The `anthropic` rail is the operator's Claude subscription: upstream
`https://api.anthropic.com/v1/messages`, credential `Authorization: Bearer <AUTH_TOKEN>` (the
OAuth token from the stack's `claude-session` Secret). claude-code sends the beta
`oauth-2025-04-20` only when IT holds the OAuth token; through the gateway it does not, so the
gateway **adds** `anthropic-beta: oauth-2025-04-20`, merged with any inbound beta list (the old
proxy's `OAUTH_BETA` precedent). The rail speaks the anthropic dialect only: an openai-dialect
request on a session pinned here is 501 `dialect-unsupported-on-rail`, and so is the models
list. Upstream 429 passes through with its `retry-after`; upstream 401/403 is 502
`upstream-auth` with no upstream body; timeouts are connect 10 s / read 600 s.

| description | inbound header || upstream header |
|---|---||---|
| "the credential is the OAuth token as a bearer" | `Authorization: Bearer gws_…` || `Authorization: Bearer <AUTH_TOKEN>` |
| "no x-api-key reaches upstream" | `x-api-key: gws_…` || no `x-api-key` |
| "the OAuth beta is added" | no `anthropic-beta` || `anthropic-beta: oauth-2025-04-20` |
| "the OAuth beta is merged, not replaced" | `anthropic-beta: interleaved-thinking-2025-05-14` || `anthropic-beta: interleaved-thinking-2025-05-14,oauth-2025-04-20` |
| "the OAuth beta is never duplicated" | `anthropic-beta: oauth-2025-04-20` || `anthropic-beta: oauth-2025-04-20` |
| "anthropic-version passes through" | `anthropic-version: 2023-06-01` || `anthropic-version: 2023-06-01` |
| "the claude-code session id passes through" | `X-Claude-Code-Session-Id: <uuid>` || `X-Claude-Code-Session-Id: <uuid>` |
| "the user agent passes through" | `User-Agent: claude-cli/2.1.281` || `User-Agent: claude-cli/2.1.281` |

| description | inbound path | upstream behaviour || status | body | recorded on the session |
|---|---|---||---|---|---|
| "a messages call lands" | `POST /anthropic/v1/messages` | upstream-ok || 200 | the upstream body, byte-identical | `requests` +1, `tokens_in` = `usage.input_tokens`, `tokens_out` = `usage.output_tokens` |
| "a streamed call streams" | `POST /anthropic/v1/messages`, `stream: true` | upstream-stream || 200 | the SSE bytes, unchanged, as they arrive | `requests` +1; tokens from the final `message_delta` usage when present, else unchanged ⚖ |
| "a rate limit passes through" | `POST /anthropic/v1/messages` | upstream-429 || 429 | the upstream body | `requests` +1 |
| "an upstream auth failure is typed and hidden" | `POST /anthropic/v1/messages` | upstream-401 || 502 | `upstream-auth` envelope — not the upstream body | `requests` +1 |
| "the openai dialect is not served on the subscription" | `POST /openai/v1/chat/completions` | (no upstream call) || 501 | `dialect-unsupported-on-rail` | nothing |
| "the models list is not served on the subscription" | `GET /openai/v1/models` | (no upstream call) || 501 | `dialect-unsupported-on-rail` | nothing |
| "🚧 WIP: a read past 600 s" | `POST /anthropic/v1/messages` | upstream-slow || 504 | `upstream-timeout` | `requests` +1 |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-RAIL-ANTHROPIC.md"

</details>

## GW-RAIL-OPENCODE

The `opencode` rail is the OpenCode Go subscription, served from the gateway's own mounted key.
Both dialects are spoken: anthropic → `https://opencode.ai/zen/go/v1/messages` with
`x-api-key: <go key>`; openai → `https://opencode.ai/zen/go/v1/chat/completions` with
`Authorization: Bearer <go key>`; `GET /openai/v1/models` → `https://opencode.ai/zen/go/v1/models`.
`anthropic-beta` is **dropped** on this rail. The vendor routes by a session id and 400s
(`MissingSessionID`) without one — measured, not argued
([chainless-redesign.md §Proved on the wire, 2026-09-17](../../../docs/agents/chainless-redesign.md)):
either `X-Claude-Code-Session-Id` or `x-opencode-session` alone clears the gate and carries
prompt-cache affinity, so both pass through untouched. ⚖ A request carrying **neither** gets
`x-opencode-session: <gateway session id>` — a per-ride bucket, the granularity the 09-17 re-read
found correct (the credential-ref fallback bucketed too coarsely). The body's `model` is the
policy id with `opencode-go/` removed ([GW-MODEL-RESOLVE](#gw-model-resolve)).

| description | dialect | inbound header || upstream header |
|---|---|---||---|
| "the Go key rides as x-api-key on the anthropic dialect" | anthropic | `Authorization: Bearer gws_…` || `x-api-key: <go key>` |
| "no bearer reaches the Go anthropic endpoint" | anthropic | `Authorization: Bearer gws_…` || no `Authorization` |
| "the Go key rides as a bearer on the openai dialect" | openai | `Authorization: Bearer gws_…` || `Authorization: Bearer <go key>` |
| "anthropic-beta is dropped" | anthropic | `anthropic-beta: oauth-2025-04-20` || no `anthropic-beta` |
| "the claude-code session id passes through alone" | anthropic | `X-Claude-Code-Session-Id: <uuid>`, no `x-opencode-session` || `X-Claude-Code-Session-Id: <uuid>`, no `x-opencode-session` |
| "the opencode session id passes through alone" | openai | `x-opencode-session: <id>` || `x-opencode-session: <id>` |
| "both session headers pass through" | anthropic | both || both, unchanged |
| "no session header — the gateway supplies its session id ⚖" | anthropic | neither || `x-opencode-session: <gateway session id>` |
| "the user agent passes through" | openai | `User-Agent: opencode/1.18.21` || `User-Agent: opencode/1.18.21` |

| description | inbound path | upstream behaviour || upstream URL | status | body |
|---|---|---||---|---|---|
| "an anthropic-dialect call lands" | `POST /anthropic/v1/messages` | upstream-ok || `https://opencode.ai/zen/go/v1/messages` | 200 | byte-identical |
| "an openai-dialect call lands" | `POST /openai/v1/chat/completions` | upstream-ok || `https://opencode.ai/zen/go/v1/chat/completions` | 200 | byte-identical |
| "the models list passes through" | `GET /openai/v1/models` | upstream-ok || `https://opencode.ai/zen/go/v1/models` | 200 | byte-identical |
| "a stream streams" | `POST /openai/v1/chat/completions`, `stream: true` | upstream-stream || `…/chat/completions` | 200 | SSE bytes unchanged |
| "a rate limit passes through" | `POST /anthropic/v1/messages` | upstream-429 || `…/messages` | 429 | the upstream body, `retry-after` kept |
| "an upstream auth failure is typed and hidden" | `POST /openai/v1/chat/completions` | upstream-401 || `…/chat/completions` | 502 | `upstream-auth` envelope |
| "the vendor's MissingSessionID is passed through, not masked ⚖" | `POST /anthropic/v1/messages` (fake rejects the supplied id as absent) | 400 `MissingSessionID` || `…/messages` | 400 | the upstream body |
| "🚧 WIP: a read past 600 s" | `POST /anthropic/v1/messages` | upstream-slow || `…/messages` | 504 | `upstream-timeout` |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-RAIL-OPENCODE.md"

</details>

## GW-MODEL-RESOLVE

A session pins one model; **no caller names a model**. The body's `model` is resolved against
the session: it must name the session's model (as the harness spells it), else 403
`model-not-session`, logged with the session id and both names. The **wire id** sent upstream
is the policy id with its rail prefix removed — `opencode-go/x` → `x` on the Go rail; an
openrouter id is already bare. ⚖ On the `anthropic` rail the policy names an alias
(`claude/sonnet`, as `model-classes.json` spells it) that the claude CLI resolves to a dated id
before the request leaves the pod, so the check there is by **family** (the alias name is a
prefix-family of the dated id: `sonnet` ⊂ `claude-sonnet-4-6`) and the body is forwarded
**untouched** — the old proxy's own self-test pins "anthropic leg: model untouched". An absent
`model` is filled with the wire id. The ADR-096 ladder — classes, label tiers, strikes,
cooldowns, provider pins, the `:exacto` suffix — is a gap, rendered below.

| description | session model (policy) | rail | body `model` || verdict | upstream body `model` |
|---|---|---|---||---|---|
| "the Go wire id is the policy id without its prefix" | opencode-go/deepseek-v4-flash | opencode | `deepseek-v4-flash` || forwarded | `deepseek-v4-flash` |
| "the openrouter wire id is the policy id itself" | deepseek/deepseek-v4-flash | openrouter | `deepseek/deepseek-v4-flash` || forwarded | `deepseek/deepseek-v4-flash` |
| "an absent model is filled" | opencode-go/deepseek-v4-flash | opencode | (absent) || forwarded | `deepseek-v4-flash` |
| "a different model is refused" | opencode-go/deepseek-v4-flash | opencode | `claude-sonnet-4-6` || 403 model-not-session | — |
| "the policy spelling is not the wire spelling" | opencode-go/deepseek-v4-flash | opencode | `opencode-go/deepseek-v4-flash` || 403 model-not-session ⚖ | — |
| "an anthropic alias matches its family ⚖" | claude/haiku | anthropic | `claude-haiku-4-5` || forwarded | `claude-haiku-4-5` (untouched) |
| "an anthropic alias refuses another family" | claude/sonnet | anthropic | `claude-haiku-4-5` || 403 model-not-session | — |
| "a bare alias in the body matches ⚖" | claude/sonnet | anthropic | `sonnet` || forwarded | `sonnet` (untouched) |
| "a Go-rail claude id is exact, not family" | opencode-go/claude-sonnet-4-6 | opencode | `claude-sonnet-4-6` || forwarded | `claude-sonnet-4-6` |
| "a Go-rail claude id refuses a dated sibling" | opencode-go/claude-sonnet-4-6 | opencode | `claude-sonnet-4-5` || 403 model-not-session | — |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: provider pin / `:exacto`" | openrouter session, policy `deepseek/deepseek-v4-flash` || the bare id, no `provider` block injected | ADR-096 M4 pins and the `provider_policy: exacto` suffix |
| "⚑ gap: a per-task deny list" | claim `modelDeny` names the session's model || dispatched anyway | the claim's `modelDeny` projection into the policy |
| "⚑ gap: a mid-session model change" | a strike on this session || the same model until release | strikes / cooldowns / the pair hold |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-MODEL-RESOLVE.md"

</details>

## GW-CRED-BOUNDARY

Pods never see a real key. Inbound, the only credential is the session token —
`Authorization: Bearer gws_…` or `x-api-key: gws_…` (claude-code sends the former through
`ANTHROPIC_AUTH_TOKEN`; some SDKs the latter). The inbound auth header **never** reaches
upstream; the upstream credential is injected from the session's rail
([GW-CRED-RESOLVE](sessions.md#gw-cred-resolve)) and hop-by-hop headers are stripped. An
unknown, expired or released token is a typed 401; a resolvable session whose credential
cannot be read is 401 `credential-unresolved` (definitive) or 503 `credential-transient`.
Upstream 401/403 is 502 `upstream-auth` with no upstream body — a key hint never crosses back.

| description | `Authorization` | `x-api-key` || verdict |
|---|---||---|---|
| "a bearer session token" | `Bearer gws_<valid>` | — || session resolved |
| "an x-api-key session token" | — | `gws_<valid>` || session resolved |
| "the bearer is consulted first ⚖" | `Bearer gws_<valid A>` | `gws_<valid B>` || session A |
| "no credential" | — | — || 401 session-unknown |
| "a token nobody minted" | `Bearer gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA` | — || 401 session-unknown |
| "a real-looking key is not a session" | `Bearer sk-or-v1-FAKE…` | — || 401 session-unknown; never forwarded; logged redacted |
| "a released session's token" | `Bearer gws_<released>` | — || 401 session-released |
| "an expired session's token" | `Bearer gws_<expired>` | — || 401 session-expired |
| "a session whose credential went away" | `Bearer gws_<valid>`, ref now a definitive miss | — || 401 credential-unresolved |
| "a session whose credential read is failing" | `Bearer gws_<valid>`, ref transient | — || 503 credential-transient |

| description | inbound header || reaches upstream |
|---|---||---|
| "the inbound bearer is stripped" | `Authorization: Bearer gws_…` || no (replaced by the rail credential) |
| "the inbound x-api-key is stripped" | `x-api-key: gws_…` || no (replaced on the Go anthropic leg; absent elsewhere) |
| "hop-by-hop headers are stripped" | `Connection`, `Keep-Alive`, `Transfer-Encoding`, `TE`, `Trailer`, `Upgrade`, `Proxy-Authorization` || no |
| "content-type passes through" | `Content-Type: application/json` || yes |
| "an unknown vendor header passes through" | `x-foo: bar` || yes |

| description | upstream behaviour || status | body | log |
|---|---||---|---|---|
| "an upstream 401 never leaks" | upstream-401 (body names the key) || 502 | `upstream-auth` envelope | `upstream-auth <rail> 401`, no body |
| "an upstream 403 is the same class" | upstream-403 || 502 | `upstream-auth` envelope | `upstream-auth <rail> 403` |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CRED-BOUNDARY.md"

</details>
