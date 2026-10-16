---
id: EP-OPENAI-RESPONSES
use-cases: [UC-1]
schema: openai-responses.schema.json
---
# POST /openai/v1/responses — the `responses` dialect, on the codex rail (ships dark)

The data-plane path a `codex` harness rides: OpenAI **Responses** over SSE (today's `openai`
dialect stays Chat Completions — [glossary: dialect](../glossary.md#dialect)). Only the `codex`
rail serves it — the operator's ChatGPT subscription — and that rail **ships dark**: the deployed
policy (`argocd/resources/agent-gateway/configmap-policy.yaml`) declares no codex rail, and even a
policy that declares one gets a credential backend only when `create_app` is handed a credential
store, which production does not do yet (the write-back is a `⚑ gap`). Every row below runs
offline against fake upstreams and the FAKE store; no real Codex/OpenAI credential exists in it.
The design and the prototype it was ported from:
[the Codex subscription-rail spike](../../../docs/spikes/codex-subscription-rail.md#gateway-prototype--isolated-build-2026-10-16-fu-270)
(FU-270) and `experiments/codex-rail/` (its native-CLI compat harness remains there).

Per request: the session token is resolved ([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary));
the body's model is checked exactly ([GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve));
the body's mode is checked ([GW-RAIL-CODEX](#gw-rail-codex)); the access credential comes from the
OAuth lifecycle ([GW-CODEX-OAUTH](#gw-codex-oauth)); the stream relays byte-unchanged while a
bounded parser counts the terminal usage once. Admission onto the rail is gated by account
headroom ([GW-CODEX-HEADROOM](#gw-codex-headroom)), composed into
[GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit)'s walk.

## Interface — the machine half

**[`openai-responses.schema.json`](openai-responses.schema.json)** holds the inbound envelope the
gateway inspects, the upstream contract (the complete header set), the headroom report schema, the
admission reasons and the error envelope.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-RAIL-CODEX](#gw-rail-codex) | `input.body` (`model`, `stream`, `store`, `input`), `upstream.codex`, `output` | `malformed-body`, `responses-mode-unsupported`, `responses-input-invalid`, `model-not-session`, `dialect-unsupported-on-rail`, `upstream-auth`, `upstream-http-error`, `upstream-content-type`, `upstream-unreachable`, `upstream-timeout` | v0, dark — the upstream profile, vendor header compatibility and the live canary are `⚑ gap` (rows below); `upstream-timeout` rows `🚧 WIP`; `⚑ gap (2026-10-16, PR #2646 → work #2650)`: native-CLI turn evidence is local-only (the "⚖ local evidence" row) |
| [GW-CODEX-HEADROOM](#gw-codex-headroom) | `headroom.report`, `admission.reasons` | — | v0, dark — authenticated report ingress and the codex window gauges are `⚑ gap` |
| [GW-CODEX-OAUTH](#gw-codex-oauth) | `upstream.codex.auth`, `credential_errors` | `credential-store-unavailable`, `credential-recovery-required`, `credential-revoked`, `credential-refresh-uncertain`, `credential-invalid`, `credential-unresolved`, `credential-transient` | v0 with the FAKE store only — the production write-back, the refresh exchange transport and lost-rotation recovery are `⚑ gap` |
| [GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve) (owned there) | `input.body.model` | `model-not-session` | linked — exact on this rail |
| [GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary) (owned there) | `input.headers.authorization` | `session-unknown`, `session-expired`, `session-released` | linked |
| [GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit) (owned there) | `admission.reasons` | — | linked — the headroom defers are three more `defer.reason` values |
| [GW-SESSIONS-ENV](sessions.md#gw-sessions-env) (owned there) | — | — | linked — the codex harness's env rows |

Rows run against the **`policy-codex` world** ([worlds/policy-codex.json](../worlds/policy-codex.json):
`policy-default` plus a codex rail that only `prober` may ride, with the fixture model
`codex/fixture-model` → wire `fixture-model`) unless a row names `policy-default`. "A codex
session" = `POST /sessions {role: prober, harness: codex}` after a fresh headroom observation;
the stored credential is one second from expiry, so the first request rotates it once.

## GW-RAIL-CODEX

The `codex` rail serves one shape: **streaming** Responses with **`store: false`** and an
**array** `input` — what the pinned Codex CLI sends (`experiments/codex-rail/evidence.json`). Any
other mode is a 400 before the credential is touched. The body's `model` must equal the session's
wire id exactly (absent = filled, as on every rail). Upstream: `<CODEX_UPSTREAM>/responses` — the
upstream base has **no default** (the Codex backend `chatgpt.com/backend-api/codex` vs the
Sign-in-with-ChatGPT preview is unselected, ⚑ below). The upstream header set is **complete and
fixed**: `authorization: Bearer <access token>`, `chatgpt-account-id: <the credential's account>`,
`content-type: application/json`, `accept: text/event-stream`, `accept-encoding: identity`,
`user-agent: agent-gateway` — no inbound header crosses, so a caller can never select an account or smuggle a cookie. A 200 SSE
answer relays **byte-unchanged**; a parser bounded per event (1 MiB) watches for the terminal
event and counts its `usage` **once** into the four token classes (`in` = `input_tokens` −
`input_tokens_details.cached_tokens`, `cache_read` = the cached count, no cache-write class, `out` =
`output_tokens`; missing or malformed usage is unknown — nothing counted, never a zero claimed).
`response.failed` / `response.incomplete` / `error` keep their own outcome; EOF or `[DONE]`
without a terminal is **truncated**; an invalid or oversized event **ends the stream** before its
bytes reach the client ⚖ (the client's own completion check sees the missing terminal; the
gateway never invents an event). Upstream is closed exactly once on every path — completion,
failure, client cancellation — and a generation is never retried once a byte reached the client.

### The request boundary

| description | inbound || status | code | upstream called |
|---|---||---|---|---|
| "a streaming, store-off, array-input request lands" | `stream: true`, `store: false`, `input: [...]`, `model: fixture-model` || 200 | — | once |
| "an absent model is filled with the wire id" | no `model` || 200 | — | once, with `model: fixture-model` |
| "another model is refused" | `model: gpt-other` || 403 | model-not-session | no |
| "a non-streaming request is refused" | `stream: false` || 400 | responses-mode-unsupported | no |
| "server-side storage is refused" | `store: true` || 400 | responses-mode-unsupported | no |
| "a string input is refused" | `input: "hi"` || 400 | responses-input-invalid | no |
| "a body that is not a JSON object" | `[]` || 400 | malformed-body | no |
| "no session token" | no `Authorization` || 401 | session-unknown | no |
| "a codex session on the chat path" | `POST /openai/v1/chat/completions` || 501 | dialect-unsupported-on-rail | no |
| "a non-codex session on the responses path" | an opencode worker session || 501 | dialect-unsupported-on-rail | no |

### Header replacement

| description | inbound header || upstream header |
|---|---||---|
| "the session token becomes the rail's access token" | `Authorization: Bearer gws_…` || `authorization: Bearer <rotated access token>` |
| "the account comes from the credential, never the caller" | `ChatGPT-Account-ID: attacker` || `chatgpt-account-id: dummy-account` |
| "no inbound header crosses ⚖" | `Cookie`, `x-api-key`, `x-foo`, `User-Agent: codex_exec/…`, `OpenAI-Beta` || none of them (`user-agent: agent-gateway`) — the set is exactly the six above (+ the transport's `host`, `content-length`, `connection`) |
| "the stream is asked for unencoded ⚖" | `Accept-Encoding: gzip` || `accept-encoding: identity`, `accept: text/event-stream` |

### Streams and usage

| description | upstream behaviour || client bytes | outcome | recorded (status, in, cache_read, cache_write, out) |
|---|---||---|---|---|
| "a completed stream relays byte-unchanged and counts once" | upstream-ok (usage 7 in / 3 out) || identical | completed | (200, 7, 0, 0, 3) |
| "cached input is its own class ⚖" | upstream-ok-cached (`input_tokens` 312, cached 300, out 7) || identical | completed | (200, 12, 300, 0, 7) |
| "a second terminal event never replaces usage" | upstream-stream-duplicate (a second `response.completed`, usage 99/99) || identical | completed | (200, 7, 0, 0, 3) |
| "a failed terminal is not a completion ⚖" | upstream-stream-failed || identical | failed | (200, 7, 0, 0, 3) |
| "an incomplete terminal is not a completion ⚖" | upstream-stream-incomplete || identical | incomplete | (200, 7, 0, 0, 3) |
| "EOF without a terminal is truncation ⚖" | upstream-stream-truncated || identical (no terminal event) | truncated | (502, 0, 0, 0, 0) |
| "an invalid event ends the stream before its bytes ⚖" | upstream-stream-invalid || a prefix of the events before it (chunking decides how much), never it | protocol-error | (502, 0, 0, 0, 0) |

### Upstream failures

| description | upstream behaviour || status | body | upstream calls |
|---|---||---|---|---|
| "an upstream 401 is typed and hidden" | upstream-401 || 502 | `upstream-auth` envelope, never the upstream body | 1 |
| "an upstream 403 is the same class" | upstream-403 || 502 | `upstream-auth` | 1 |
| "a rate limit passes through ⚖" | upstream-429 || 429 | the upstream body, `retry-after: 30` kept | 1 |
| "an upstream 5xx is typed ⚖" | upstream-500 || 502 | `upstream-http-error` | 1 |
| "a redirect is never followed" | upstream-302 (`Location` → loopback) || 502 | `upstream-http-error` | 1 — the location is never fetched |
| "a non-SSE 200 is refused ⚖" | upstream-wrong-type (`application/json`) || 502 | `upstream-content-type` | 1 |
| "an unreachable upstream is typed" | upstream-down || 502 | `upstream-unreachable` | 0 |
| "🚧 WIP: a read past the read timeout" | upstream-slow (clock-faked) || 504 | `upstream-timeout` | 0 |

### The relay seam (driven at `responses.relay` with synthetic chunks)

| description | chunks || outcome | bytes out | upstream closes |
|---|---||---|---|---|
| "every byte split of a CRLF stream parses" | a heartbeat + one completed event in CRLF, split at every offset || completed, usage 7 / 3 | identical | 1 |
| "a multi-line data field is one event" | one completed event across two `data:` lines, one byte per chunk || completed | identical | 1 |
| "terminal usage after 4 MiB of deltas is counted" | 100 000 delta events, then a terminal || completed, usage 7 / 3 | identical (> 4 MiB) | 1 |
| "malformed usage is unknown, not zero" | `input_tokens: true`, `output_tokens: -1` || completed, usage unknown | identical | 1 |
| "an oversized event is refused ⚖" | one event over the bound || protocol-error | none of it | 1 |
| "a completed event with another status is invalid" | `response.completed` with `status: failed` || protocol-error | none of it | 1 |
| "[DONE] alone is truncation" | `data: [DONE]` || truncated | identical | 1 |
| "a non-object event is invalid" | `data: []` || protocol-error | none of it | 1 |
| "a transport fault mid-stream is sanitised" | one chunk, then the transport raises with secret text || transport-error | the first chunk | 1 |
| "a cancelled download closes upstream without draining" | the consumer stops after the first chunk || cancelled | the first chunk | 1; the second chunk is never pulled |

### Named gaps and local evidence

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: the upstream profile" | `CODEX_UPSTREAM` unset || no backend — admission defers `credential-unresolved` | the Codex backend vs the SIWC preview; each needs backend-specific request/header fixtures |
| "⚑ gap: vendor header compatibility" | the backend's session-affinity / identity headers || not sent (the fixed six) | reviewed against real backend fixtures before the canary |
| "⚑ gap: the live canary" | a real account || never run | spike step 4 — a separately authorized maintenance window |
| "⚖ local evidence: the pinned Codex CLI completes a turn through this gateway" | `experiments/codex-rail/compat.py` (codex-cli 0.161.0, the agent-runtime lock) || a completed `codex exec --json` turn, one rotation, one upstream close | not CI: the CLI is not in the CI toolchain — dated local evidence in `experiments/codex-rail/evidence.json` |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-RAIL-CODEX.md"

</details>

## GW-CODEX-HEADROOM

The rail is admitted on **account headroom**, held by the gateway itself (no Prometheus read,
ADR-108): one immutable snapshot of normalised windows, replaced only by a **strictly newer**,
valid report. The report schema is the gateway's own (`headroom.report` in the schema), not a
vendor payload; its producer must be authenticated and account-bound — that ingress is a `⚑ gap`,
so today reports enter only through the in-process seam and a fresh gateway answers
`quota-unknown` (fail closed). Freshness (`max_age_s`), the ceiling and the window profile are
policy (`rails.codex.headroom`) — in `policy-codex` the experiment's fixture values (120 s, 0.95,
the 300- and 10080-minute windows) ⚖ — never code literals. Verdicts: `admit`, `quota-unknown`,
`quota-stale` (past freshness, a clock rollback, or a window's reset passed — a reset passing is
not evidence capacity returned), `quota-limited` (a window at or above the ceiling, or the
explicit `limited` flag). A non-`admit` verdict skips the rail in the
[GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit) walk; when it was the last candidate the
answer is `defer` with that verdict as `reason`. `retry_after_s`: for `quota-limited` by windows,
the **latest** reset among the exhausted windows minus now (every exhausted window must reset);
otherwise the policy's `defer_retry_s` (a new observation is the cure). Headroom is checked
before the credential store is read, and it reserves nothing ⚖.

### Reports

| description | report (now T; last accepted observed at T−10, 20 % / 64 %) || accepted | verdict after |
|---|---||---|---|
| "a fresh two-window report admits and normalises" | poll, observed T−10, 20 % / 64 % (first report) || yes — windows 0.20 / 0.64 | admit |
| "no report yet is unknown" | — || — | quota-unknown |
| "a gateway restart forgets" | a fresh Headroom after one report || — | quota-unknown |
| "an equal or older timestamp cannot overwrite" | observed T−10, T−11, T−110 (limited) || no — `quota-out-of-order` | admit (unchanged) |
| "a newer report from another source replaces" | jail, observed T−1, limited || yes | quota-limited |
| "a report at the freshness bound is refused" | observed T−120 || no — `quota-time-invalid` | admit (unchanged) |
| "a future report is refused" | observed T+1 || no — `quota-time-invalid` | admit (unchanged) |
| "a non-finite or bool timestamp is refused" | `true`, NaN, ∞ || no — `quota-time-invalid` | admit (unchanged) |
| "a missing or duplicated window is refused" | `windows: []`, the 5h window twice || no — `quota-invalid` | unknown (nothing accepted) |
| "a window outside the profile is refused" | `window_minutes: 301`, `true` || no — `quota-invalid` | unknown |
| "an out-of-range or non-finite percentage is refused" | −1, 101, `true`, NaN, ∞ || no — `quota-invalid` | unknown |
| "an already-passed reset is refused" | `resets_at` ≤ T, `true`, NaN || no — `quota-invalid` | unknown |
| "an unknown source or a non-bool flag is refused" | `source: untrusted`, `limited: 0`, not an object || no — `quota-invalid` | unknown |

### Verdicts

| description | snapshot (observed T−10) | now || verdict |
|---|---|---||---|
| "a window at the ceiling limits" | 95 % / 64 % | T || quota-limited |
| "either window limits" | 20 % / 95 % | T || quota-limited |
| "the explicit flag limits" | 20 % / 64 %, `limited: true` | T || quota-limited |
| "the freshness bound is stale ⚖" | 20 % / 64 % | T+110 (age 120) || quota-stale |
| "a clock rollback is stale" | 20 % / 64 % | T−20 || quota-stale |
| "a reset passing is stale, not replenished ⚖" | 5h resets at T+10 | T+10 || quota-stale |

### Admission

| description | headroom || decision | reason | retry_after_s |
|---|---||---|---|---|
| "fresh headroom admits the codex harness" | 20 % / 64 % || dispatch on codex | — | — |
| "no observation defers unknown" | — || defer | quota-unknown | 60 (`defer_retry_s`) |
| "a stale observation defers stale" | observed T−10, asked at T+115 || defer | quota-stale | 60 |
| "an exhausted window defers until its reset ⚖" | 96 % / 64 %, 5h resets T+1000 || defer | quota-limited | 1000 |
| "two exhausted windows wait for the later reset ⚖" | 96 % / 97 %, resets T+1000 / T+8000 || defer | quota-limited | 8000 |
| "the explicit flag alone defers by the policy interval ⚖" | 20 % / 64 %, `limited: true` || defer | quota-limited | 60 |
| "headroom is read before the credential store ⚖" | no observation, the store would fail || defer | quota-unknown — the store was never read | 60 |
| "the rail's session cap still applies" | fresh; 2 codex sessions active (`max_sessions` 2) || defer | rail-capacity | 60 |
| "an admitted session is not re-gated on the data plane ⚖" | dispatched at 20 %, then a limited report || data plane 200 | — (an upstream 429 is the in-session signal) | — |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: authenticated report ingress" | a poll of the account usage endpoint, a jail `rate_limits` event, upstream headers || none reach the gateway | the token-gated ingest + the usage poll (spike §Candidate shape) |
| "⚑ gap: codex window gauges" | an accepted report || no `gateway_subscription_*{rail="codex"}` series | the report → gauge wiring and the dashboard panels |
| "⚑ gap: reservation" | two admissions at 94 % || both dispatched | reports do not meter concurrent use; the session cap is the only bound |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CODEX-HEADROOM.md"

</details>

## GW-CODEX-OAUTH

The codex credential is a refreshable OAuth record (`access_token`, `refresh_token`, `account_id`,
`expires_at`) held behind a **persistence interface**: one account per store; `lock()` exclusive
across all owners and held across load → exchange → save; `save` atomic and acknowledged only when
durable; a `save` exception may have committed, so the next call reloads. The lifecycle returns
the stored access token while it is more than `refresh_margin_s` (policy, 30 s in `policy-codex`)
from expiry; otherwise it persists `refreshing` **before** contacting upstream, exchanges once,
and returns the replacement only after saving it `ready`. A persisted `refreshing` — a crash, an
uncertain exchange, an invalid replacement — fails closed as `credential-recovery-required` and is
never retried automatically (replaying a rotated refresh token is the one unrecoverable move). An
authoritative revocation persists `revoked`. No failure carries a credential in its message, its
exception chain or any repr. The ONLY store is the tests' FAKE (process memory); production wires
none, so the rail ships dark — the write-back belongs to Infisical, the source of truth
([secrets doctrine](../../../docs/secrets.md)), and is a `⚑ gap`.

On the data plane a lifecycle failure answers before upstream is contacted:
`credential-store-unavailable` → 503 with `retry-after` (the store may answer next time); every
other code → 401 with that code (a durable state only an operator act changes). At admission the
durable state is read without refreshing: `ready` admits, `revoked` / `refreshing` skip the rail
(`credential-unresolved`), a store that does not answer is 503 `credential-transient`.

### The lifecycle (driven at `oauth.Lifecycle` with the FAKE store)

| description | store state, exchange || result | exchanges | durable state after |
|---|---||---|---|---|
| "concurrent owners share one rotation" | ready, near expiry; 16 owners at once || every owner gets the rotation | 1 | ready, rotated refresh token |
| "a fresh credential is returned without refresh" | ready, 100 s from expiry || the stored credential | 0 | unchanged |
| "the marker is durable before the exchange" | ready, near expiry || rotated | 1 — it saw `refreshing` | ready |
| "a failed marker write prevents the exchange" | marker save raises || credential-store-unavailable; the next acquire rotates | 0, then 1 | ready |
| "a failed rotation write blocks restart" | rotation save raises || credential-store-unavailable, then credential-recovery-required | 1 | refreshing |
| "an ambiguous save reloads the committed rotation" | rotation save commits, then raises || credential-store-unavailable, then the rotation | 1 | ready, rotated |
| "a crash after the exchange requires recovery ⚖" | the process dies after the exchange || credential-recovery-required on restart | 1 | refreshing |
| "an uncertain exchange is never retried ⚖" | the exchange times out || credential-refresh-uncertain, then credential-recovery-required | 1 | refreshing |
| "revocation survives restart" | the exchange says revoked || credential-revoked, then credential-revoked | 1 | revoked |
| "explicit revocation blocks a cached access token" | ready, fresh; `revoke()` || credential-revoked | 0 | revoked |
| "an invalid rotation fails closed" | another account / CR-LF in a token / NaN expiry / already expired / none || credential-invalid, then credential-recovery-required | 1 each | refreshing |
| "a lock failure is the store class" | the lock raises || credential-store-unavailable | 0 | unchanged |
| "the next refresh uses the persisted rotation" | rotated once, near expiry again || the third credential, exchanged from the rotated one | 2 | ready |
| "a failed revocation save still blocks restart ⚖" | revoked; that save raises || credential-store-unavailable, then credential-recovery-required | 1 | refreshing |
| "a committed-then-failed marker never exchanges" | marker save commits, then raises || credential-store-unavailable, then credential-recovery-required | 0 | refreshing |
| "no record or failure shows a credential" | any of the above || reprs, messages and tracebacks hold no `DUMMY-SECRET` | — | — |

### Through the gateway

| description | world || admission | data plane |
|---|---||---|---|
| "a near-expiry credential rotates on first use" | stored credential 1 s from expiry || dispatch | 200; upstream bearer = the rotated access token; one exchange |
| "a revoked credential is not admissible ⚖" | durable state revoked || defer `credential-unresolved` | — |
| "a recovery-required credential is not admissible ⚖" | durable state refreshing || defer `credential-unresolved` | — |
| "a store that does not answer at admission is transient ⚖" | the store's lock raises || 503 `credential-transient` | — |
| "a revocation mid-session refuses before upstream" | admitted, then revoked || — | 401 `credential-revoked`; upstream not called |
| "an uncertain refresh refuses, then stays refused" | the exchange times out || — | 401 `credential-refresh-uncertain`, then 401 `credential-recovery-required` |
| "a store fault on the data plane is retriable ⚖" | the marker save raises || — | 503 `credential-store-unavailable`, `retry-after: 60` |
| "no backend: the rail is a definitive miss" | `policy-codex`, `create_app` without a store || defer `credential-unresolved` | — |
| "the deployed policy declares no codex rail" | `argocd/resources/agent-gateway/configmap-policy.yaml` || `rails` has no `codex` key — the rail ships dark | — |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: production write-back" | a rotation in production || no store is wired | Infisical write-back (the source of truth); updating only the ESO-generated Secret risks restoring an obsolete refresh token |
| "⚑ gap: the refresh exchange" | a near-expiry credential in production || no exchange exists | the OAuth token-endpoint transport, its timeouts and revocation mapping |
| "⚑ gap: lost-rotation recovery" | a crash between the exchange and the save || recovery-required forever | an explicitly designed recovery operation with an authoritative replacement |
| "⚑ gap: cross-process fencing" | two gateway replicas || one replica only (ADR-139) | distributed fencing — FU-271 |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CODEX-OAUTH.md"

</details>
