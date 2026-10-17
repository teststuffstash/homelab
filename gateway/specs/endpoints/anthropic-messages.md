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
| [GW-RAIL-ANTHROPIC](#gw-rail-anthropic) | `upstream.anthropic` (URL, auth, `anthropic-beta`), `output.complete` | `upstream-auth`, `upstream-unreachable`, `upstream-timeout` | v0 |
| [GW-RAIL-OPENCODE](#gw-rail-opencode) | `upstream.opencode` (URL, auth, session headers), `input.headers.x-opencode-session`, `input.headers.x-claude-code-session-id` | `upstream-auth`, `upstream-unreachable`, `upstream-timeout` | v0; `upstream-timeout` rows `🚧 WIP` (the `upstream-slow` world is clock-faked only) |
| [GW-MODEL-RESOLVE](#gw-model-resolve) | `input.body.model` | `model-not-session` | v0 — provider pins / `:exacto` / the ADR-096 ladder `⚑ gap` (rows below) |
| [GW-CRED-BOUNDARY](#gw-cred-boundary) | `input.headers.authorization`, `input.headers.x-api-key`, `upstream.*.auth` | `session-unknown`, `session-expired`, `session-released`, `credential-unresolved`, `credential-transient`, `upstream-auth`, `upstream-refused`, `upstream-edge-refused`, `header-refused` | v0; the codex rail's `upstream-auth` is still 502 (`⚑ gap` row below) |
| [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter) (owned on openai-chat.md) | `upstream.openrouter` | `upstream-auth`, `upstream-unreachable` | linked — the anthropic-dialect cell is a verified row there |
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
list. Upstream 429 passes through with its `retry-after`; upstream 401/403 is 424
`upstream-auth`, 403 `upstream-refused` or 403 `upstream-edge-refused` ([GW-CRED-BOUNDARY](#gw-cred-boundary))
with no upstream body; timeouts are connect 10 s / read 600 s (504
`upstream-timeout`); a connection that fails for any other reason — refused, DNS, TLS, reset —
is 502 `upstream-unreachable` (nothing reached the vendor; the row counts, so a dead upstream
is visible on the session and in `gateway_requests_total{status="502"}`).

**Stream completeness.** A 2xx is recorded **complete** only when its body reached its end: a
non-streamed body read to its last byte, a stream that carried its terminal event — `message_stop`
on this dialect (`data: [DONE]` on the openai one, [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter)),
seen through any `content-encoding` the gateway can decode. Otherwise the request row carries
`incomplete` = `no-terminal` (the body ended without it), `timeout` (a mid-stream read timeout;
the row's status is 504), `transport-error` (the connection broke mid-body) or `client-closed` (the
pod hung up), the session's `requests_incomplete` + 1, and
`gateway_requests_incomplete_total{rail,dialect,reason}` + 1 ([GW-METRICS](metrics.md#gw-metrics)).
A broken stream is never a clean 200 with 0 tokens. The bytes the pod got are unchanged either way.
The experiment's tap (2026-10-17) saw 8 opencode streams cut by the client mid-body; the old
record showed each as a 200.

| description | inbound header || upstream header |
|---|---||---|
| "the credential is the OAuth token as a bearer" | `Authorization: Bearer gws_…` || `Authorization: Bearer <AUTH_TOKEN>` |
| "no x-api-key reaches upstream" | `x-api-key: gws_…` || no `x-api-key` |
| "the OAuth beta is added" | no `anthropic-beta` || `anthropic-beta: oauth-2025-04-20` |
| "the OAuth beta is merged, not replaced" | `anthropic-beta: interleaved-thinking-2025-05-14` || `anthropic-beta: interleaved-thinking-2025-05-14,oauth-2025-04-20` |
| "the OAuth beta is never duplicated" | `anthropic-beta: oauth-2025-04-20` || `anthropic-beta: oauth-2025-04-20` |
| "anthropic-version passes through" | `anthropic-version: 2023-06-01` || `anthropic-version: 2023-06-01` |
| "the claude-code session id passes through" | `X-Claude-Code-Session-Id: <uuid>` || `X-Claude-Code-Session-Id: <uuid>` |
| "the user agent passes through (`user_agent: forward`) ⚖" | `User-Agent: claude-cli/2.1.281` || `User-Agent: claude-cli/2.1.281` |

| description | inbound path | upstream behaviour || status | body | recorded on the session |
|---|---|---||---|---|---|
| "a messages call lands" | `POST /anthropic/v1/messages` | upstream-ok || 200 | the upstream body, byte-identical | `requests` +1, `tokens_in` = `usage.input_tokens`, `tokens_out` = `usage.output_tokens` |
| "a streamed call streams" | `POST /anthropic/v1/messages`, `stream: true` | upstream-stream || 200 | the SSE bytes, unchanged, as they arrive | `requests` +1; tokens from the final `message_delta` usage when present, else unchanged ⚖ |
| "cache classes are recorded apart" | `POST /anthropic/v1/messages` | upstream-ok-cached || 200 | the upstream body, byte-identical | (`requests`, `tokens_in`, `tokens_cache_read`, `tokens_cache_write`, `tokens_out`) = (1, 12, 300, 40, 7) — `input_tokens` already excludes the cache |
| "a gzipped stream still counts" | `POST /anthropic/v1/messages`, `stream: true` | upstream-stream-gzip || 200 | the gzip bytes, unchanged; `content-encoding: gzip` kept | `requests` +1; tokens from the DECODED final `message_delta` usage (live anthropic answers gzip SSE — FU-270) |
| "a rate limit passes through" | `POST /anthropic/v1/messages` | upstream-429 || 429 | the upstream body | `requests` +1 |
| "an upstream auth failure is typed and hidden" | `POST /anthropic/v1/messages` | upstream-401 || 424 | `upstream-auth` envelope — not the upstream body | `requests` +1 |
| "the openai dialect is not served on the subscription" | `POST /openai/v1/chat/completions` | (no upstream call) || 501 | `dialect-unsupported-on-rail` | nothing |
| "the models list is not served on the subscription" | `GET /openai/v1/models` | (no upstream call) || 501 | `dialect-unsupported-on-rail` | nothing |
| "an unreachable upstream is typed" | `POST /anthropic/v1/messages` | upstream-down || 502 | `upstream-unreachable` envelope | `requests` +1 |
| "🚧 WIP: a read past 600 s" | `POST /anthropic/v1/messages` | upstream-slow || 504 | `upstream-timeout` | `requests` +1 |

| description | upstream behaviour || recorded on the session | `gateway_requests_incomplete_total{rail="anthropic",dialect="anthropic",reason}` |
|---|---||---|---|
| "a stream that ends without message_stop is recorded incomplete" | upstream-stream-truncated (stream: true) || `requests_incomplete` 1; the request row's `incomplete` = `no-terminal` | `no-terminal` = 1 |
| "a gzipped stream's message_stop is seen through the encoding" | upstream-stream-gzip (stream: true) || `requests_incomplete` 0; `incomplete` = null | `no-terminal` = 0 |
| "the client going away mid-stream is recorded incomplete" | upstream-stream; the pod hangs up after the first chunk (the gateway's body iterator closed — the in-process client buffers whole bodies) || `requests_incomplete` 1; `incomplete` = `client-closed` | `client-closed` = 1 |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-RAIL-ANTHROPIC.md"

</details>

## GW-RAIL-OPENCODE

The `opencode` rail is the OpenCode Go subscription, served from the gateway's own mounted key.
Both dialects are spoken: anthropic → `https://opencode.ai/zen/go/v1/messages` with
`x-api-key: <go key>`; openai → `https://opencode.ai/zen/go/v1/chat/completions` with
`Authorization: Bearer <go key>`; `GET /openai/v1/models` → `https://opencode.ai/zen/go/v1/models`.
`anthropic-beta` is **dropped** on this rail. ⚖ **The User-Agent is the gateway's own**
(`user_agent: fixed`, a per-rail policy key, `fixed` by default). The caller's UA never reaches
opencode.ai, whose edge judges client signatures: it answered `Python-urllib` with a 403 block page
and accepted `agent-gateway` (probed live from the gateway pod, 2026-10-17). **Accept-Encoding is
the client's** (every rail): the upstream answers in the encoding the client asked for, and the
bytes come back unchanged. A client that sent none is sent upstream as `identity`, so it never gets
a gzip body it did not ask for (the transport's own default asked for gzip — a 2026-10-17
observation). The vendor routes by a session id and 400s
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
| "the caller's user agent is replaced by the gateway's own ⚖" | openai | `User-Agent: Python-urllib/3.13` || `User-Agent: agent-gateway` |
| "the client's Accept-Encoding passes through" | openai | `Accept-Encoding: gzip` || `Accept-Encoding: gzip` |
| "no Accept-Encoding from the client is identity upstream ⚖" | openai | (none) || `Accept-Encoding: identity` |

| description | inbound path | upstream behaviour || upstream URL | status | body |
|---|---|---||---|---|---|
| "an anthropic-dialect call lands" | `POST /anthropic/v1/messages` | upstream-ok || `https://opencode.ai/zen/go/v1/messages` | 200 | byte-identical |
| "an openai-dialect call lands" | `POST /openai/v1/chat/completions` | upstream-ok || `https://opencode.ai/zen/go/v1/chat/completions` | 200 | byte-identical |
| "the models list passes through" | `GET /openai/v1/models` | upstream-ok || `https://opencode.ai/zen/go/v1/models` | 200 | byte-identical |
| "a stream streams" | `POST /openai/v1/chat/completions`, `stream: true` | upstream-stream || `…/chat/completions` | 200 | SSE bytes unchanged |
| "a rate limit passes through" | `POST /anthropic/v1/messages` | upstream-429 || `…/messages` | 429 | the upstream body, `retry-after` kept |
| "an upstream auth failure is typed and hidden" | `POST /openai/v1/chat/completions` | upstream-401 || `…/chat/completions` | 424 | `upstream-auth` envelope |
| "the vendor's MissingSessionID is passed through, not masked ⚖" | `POST /anthropic/v1/messages` (fake rejects the supplied id as absent) | 400 `MissingSessionID` || `…/messages` | 400 | the upstream body |
| "an unreachable upstream is typed" | `POST /anthropic/v1/messages` | upstream-down || `…/messages` | 502 | `upstream-unreachable` envelope |
| "🚧 WIP: a read past 600 s" | `POST /anthropic/v1/messages` | upstream-slow || `…/messages` | 504 | `upstream-timeout` |

<details markdown="1"><summary>Evidence</summary>

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
**untouched** — the old proxy's own self-test pins "anthropic leg: model untouched". ⚖ A rail
may declare `side_models` in policy — the families a harness's own side-calls name regardless
of the session's model: claude-code makes small calls on the haiku family
(`ANTHROPIC_SMALL_FAST_MODEL`'s default) under a sonnet session, so the anthropic rail admits
the session's family **and** `claude/haiku` (seat ruling, 2026-10-16); the key lives in policy
because no model id lives in code, and a rail that declares none (the Go rail today) keeps the
exact check. An absent `model` is filled with the wire id. The ADR-096 ladder — classes, label tiers, strikes,
cooldowns, provider pins, the `:exacto` suffix — is a gap, rendered below.

| description | session model (policy) | rail | body `model` || verdict | upstream body `model` |
|---|---|---|---||---|---|
| "the Go wire id is the policy id without its prefix" | opencode-go/deepseek-v4-flash | opencode | `deepseek-v4-flash` || forwarded | `deepseek-v4-flash` |
| "the openrouter wire id is the policy id itself" | deepseek/deepseek-v4-flash | openrouter | `deepseek/deepseek-v4-flash` || forwarded | `deepseek/deepseek-v4-flash` |
| "an absent model is filled" | opencode-go/deepseek-v4-flash | opencode | (absent) || forwarded | `deepseek-v4-flash` |
| "a different model is refused" | opencode-go/deepseek-v4-flash | opencode | `claude-sonnet-4-6` || 403 model-not-session | — |
| "the policy spelling is not the wire spelling" | opencode-go/deepseek-v4-flash | opencode | `opencode-go/deepseek-v4-flash` || 403 model-not-session ⚖ | — |
| "an anthropic alias matches its family ⚖" | claude/haiku | anthropic | `claude-haiku-4-5` || forwarded | `claude-haiku-4-5` (untouched) |
| "an anthropic alias refuses another family" | claude/sonnet | anthropic | `claude-opus-4-1` || 403 model-not-session | — |
| "a bare alias in the body matches ⚖" | claude/sonnet | anthropic | `sonnet` || forwarded | `sonnet` (untouched) |
| "a claude-code haiku side-call under a sonnet session is admitted ⚖" | claude/sonnet | anthropic | `claude-haiku-4-5` || forwarded | `claude-haiku-4-5` (untouched) |
| "a bare haiku side-call under a sonnet session is admitted ⚖" | claude/sonnet | anthropic | `haiku` || forwarded | `haiku` (untouched) |
| "a side-call family is policy, not code: the Go rail declares none" | opencode-go/claude-sonnet-4-6 | opencode | `claude-haiku-4-5` || 403 model-not-session | — |
| "a Go-rail claude id is exact, not family" | opencode-go/claude-sonnet-4-6 | opencode | `claude-sonnet-4-6` || forwarded | `claude-sonnet-4-6` |
| "a Go-rail claude id refuses a dated sibling" | opencode-go/claude-sonnet-4-6 | opencode | `claude-sonnet-4-5` || 403 model-not-session | — |

| description | policy document || verdict |
|---|---||---|
| "the dispatch answer names the policy id for (rail, tier)" | `policy-default` || `model` = `rails.<rail>.models.<tier>` for every role |
| "no model id from the policy appears in src/" | `policy-default` || grep finds none |
| "the anthropic body is forwarded byte-untouched" | `policy-default` || upstream body == inbound body |
| "the deployed policy loads under the island's loader, every id known ⚖" | `argocd/resources/agent-gateway/policy.json` (skipped when absent) || loads; same rails and roles as `policy-default`; every non-opencode model and side-model id is a `models.*.ids` value of `model-classes.json`; every opencode id is `opencode-go/<id>` of an id in the gateway-owned Go catalog snapshot `tests/fixtures/go-catalog.json` (operator, 2026-10-17: `model-classes.json` is the old proxy's table and carries no Go `deepseek-v4.1-flash` id; the Go-catalog leg, `docs/spikes/opencode-go-catalog.md`, replaces the snapshot); opencode `max_sessions` = its `rails.opencode-go.concurrency` |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: provider pin / `:exacto`" | openrouter session, policy `deepseek/deepseek-v4-flash` || the bare id, no `provider` block injected | ADR-096 M4 pins and the `provider_policy: exacto` suffix |
| "⚑ gap: a per-task deny list" | claim `modelDeny` names the session's model || dispatched anyway | the claim's `modelDeny` projection into the policy |
| "⚑ gap: a mid-session model change" | a strike on this session || the same model until release | strikes / cooldowns / the pair hold |

<details markdown="1"><summary>Evidence</summary>

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
Upstream 401/403 never relays its body — a key hint never crosses back — and is told apart by
what it says (the body is read, never forwarded): a 401, or a 403 whose error names a credential
reason (`type` `authentication_error` / `permission_error`, `code` `api_key_expired` /
`invalid_api_key` / …), is **424 `upstream-auth`**: the
rail credential is bad, and the [admission](sessions.md#capacity--the-ladders-capacity-half) skips
that credential until a 2xx on it or a new value. ⚖ 424 (Failed Dependency), not 502: the pinned
harnesses retry 5xx with backoff (opencode retried the expired Go key's 502 nine times in the
2026-10-17 experiment, `docs/spikes/gateway-free-models-2026-10-17/cells.tsv`), and they retry
neither 424 nor 403 — a dead credential must end the ride, not stall it. A 403 whose JSON error object names no credential reason is a
**policy refusal**: **403 `upstream-refused`**, and the credential is untouched. ⚖ The observed one
is OpenRouter's harness gate (`… is only available on agentic harnesses`, `failed_routing_step:
Gate Free Endpoints by Agentic Harness`): the model refused this caller, and the key is fine.
⚖ A 403 with **no readable JSON error object**, such as an HTML block page or Cloudflare's
`error code: 1010`, is an **edge refusal**: **403 `upstream-edge-refused`**. A proxy in front of
the vendor judged THIS request's client signature, so the refusal is scoped to that request, never
rail-wide, and the credential is untouched. The 2026-10-17 defect: a `Python-urllib` caller's 403
1010 was read as a credential verdict (the old "unreadable 403 = credential" rule) and self-latched
the Go rail until a restart.
The boundary also runs outward: a credential-shaped value (the [GW-REDACT](sessions.md#gw-redact)
patterns) in any header the gateway does not own is 502 `header-refused` before any upstream
call — the old proxy's FU-251 tripwire; a harness that smuggles a real key in a vendor header
never gets it past this hop.

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
| "a credential-shaped value in a vendor header is refused" | `x-foo: Bearer sk-ant-oat-…` || no — 502 `header-refused`, upstream not called |

| description | upstream behaviour || status | body | log |
|---|---||---|---|---|
| "an upstream 401 never leaks" | upstream-401 (body names the key) || 424 | `upstream-auth` envelope | `upstream-auth <rail> 401`, no body |
| "an upstream 403 naming a credential reason is the same class" | upstream-403 (`permission_error`) || 424 | `upstream-auth` envelope | `upstream-auth <rail> 403` |

| description | rail | upstream behaviour || status | code | the rail's credential |
|---|---|---||---|---|---|
| "an expired key is a credential verdict ⚖" | opencode | upstream-401-key-expired (`api_key_expired`, the Go vendor's live answer) || 424 | upstream-auth | rejected: `gateway_credentials_rejected{rail="opencode"}` = 1 |
| "a policy refusal is not a credential verdict ⚖" | openrouter | upstream-403-refused (the harness gate) || 403 | upstream-refused | not rejected: `gateway_credentials_rejected{rail="openrouter"}` = 0 |
| "a refusal's body is not relayed either" | openrouter | upstream-403-refused || 403 | upstream-refused | the body names neither the gate text nor the routing step |
| "an edge's error-code 403 is not a credential verdict ⚖" | opencode | upstream-403-edge (`text/plain` `error code: 1010`) || 403 | upstream-edge-refused | not rejected: `gateway_credentials_rejected{rail="opencode"}` = 0 |
| "an edge's HTML 403 is not a credential verdict" | opencode | upstream-403-html (an HTML block page — what opencode.ai's edge answered `Python-urllib`, probed live) || 403 | upstream-edge-refused | not rejected: `gateway_credentials_rejected{rail="opencode"}` = 0 |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: the codex rail's upstream-auth" | an upstream 401/403 on the dark codex rail || 502 `upstream-auth` ([GW-RAIL-CODEX](openai-responses.md#gw-rail-codex)), no rejection mark | the codex rail's own lifecycle owns its credential verdicts (GW-CODEX-OAUTH); aligning its status waits on that rail leaving dark |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CRED-BOUNDARY.md"

</details>
