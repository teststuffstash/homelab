---
id: EP-OPENAI-RESPONSES
use-cases: [UC-1]
schema: openai-responses.schema.json
---
# POST /openai/v1/responses — the `responses` dialect, on the codex rail (lit 2026-10-22, prober-only)

The data-plane path a `codex` harness rides: OpenAI **Responses** over SSE (today's `openai`
dialect stays Chat Completions — [glossary: dialect](../glossary.md#dialect)). Only the `codex`
rail serves it — the operator's ChatGPT subscription. The rail was **lit on 2026-10-22** (FU-270)
as the explicit canary cell (the deployed policy, `argocd/resources/agent-gateway/policy.json`,
listed `rails.codex` for the `prober` role only); **since 2026-10-23 every role lists it** — the
operator's ruling that subscriptions go to all roles — and the walk reaches it without an explicit
`harness: codex` ([GW-SESSIONS-ADMIT §The harness follows the rail](sessions.md#the-harness-follows-the-rail)).
A policy that declares the rail gets a credential
backend only when `create_app` is handed a credential store: production wires gateway-local SQLite
seeded from the gateway's own login (`devbox run codex-seed`) and the native refresh. Rows run
offline against fake upstreams and dummy credentials; no real Codex/OpenAI credential exists in them.
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
| [GW-CODEX-HEADROOM](#gw-codex-headroom) | `headroom.report`, `headroom.poll`, `headroom.upstream`, `admission.reasons` | — | v0 — two report producers, both the gateway's own: its usage poll (§Poll) and the relayed answers' `x-codex-*` headers (§Upstream headers); the jail ingress stays `⚑ gap` |
| [GW-CODEX-OAUTH](#gw-codex-oauth) | `upstream.codex.auth`, `credential_errors` | `credential-store-unavailable`, `credential-recovery-required`, `credential-revoked`, `credential-refresh-uncertain`, `credential-invalid`, `credential-unresolved`, `credential-transient` | gateway-local SQLite with hash-gated seed recovery; live durability remains unverified |
| [GW-CODEX-REFRESH](#gw-codex-refresh) | `refresh` | `credential-revoked`, `credential-refresh-uncertain`, `credential-recovery-required` | native transport wired; rail absent from policy |
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
upstream base has **no default**; the deployment selects the native Codex backend
`https://chatgpt.com/backend-api/codex` (operator ruling 2026-10-19). SIWC is unselected. The upstream base header set is **complete and
fixed**, with the bounded turn-state exception below: `authorization: Bearer <access token>`, `chatgpt-account-id: <the credential's account>`,
`content-type: application/json`, `accept: text/event-stream`, `accept-encoding: identity`,
`user-agent: agent-gateway` — only a previously issued turn-state may return, so a caller can never select an account or smuggle a cookie. A 200 SSE
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

### Opaque turn state

`x-codex-turn-state` is the sole optional routing-header round trip. The gateway records only
an upstream-issued value from a successful SSE response, bound to authenticated session,
gateway-owned account, and the pinned client's `client_metadata.turn_id`. A new turn clears
it. The first value wins within a turn (the native client's OnceLock behavior). A request may
return only that exact value; otherwise 400 `turn-state-invalid`, without an inference call.
No account header, cookie or other caller header crosses. A missing/invalid turn ID disables
state issuance. Restart or eviction requires a fresh turn; state is not durable.
⚖ Bounds: printable ASCII, 4096 bytes for state, 128 for turn ID, 1024 session entries (LRU).
Oversized/invalid upstream state is dropped. A delayed old-turn response cannot install state
into the newer turn. These are gateway judgments, not vendor limits.

| description | sequence || replay |
|---|---||---|
| "same session and turn" | issue, replay || accepted |
| "another session" | issue, cross session replay || refused |
| "new turn clears state" | issue, next turn replay || refused |
| "forged state" | no issue, replay || refused |
| "oversized state ⚖" | upstream issues 4097 bytes || dropped (not refused): no state header to the client, a replay of it is 400 |
| "delayed old turn response ⚖" | new turn before old response || dropped (not refused): the old turn's value never installs into the newer turn; a replay of it is 400 |

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
| "a 200 with no content-type is relayed as a stream ⚖" | upstream-ok-no-ctype (SSE, no `content-type` header at all) || 200 — the stream completes; an INFO line says the header was absent | — (the bounded parser's `protocol-error` is the guard against a non-SSE body) | 1 |
| "a refused answer is captured: content-type, header names, a bounded preview ⚖" | upstream-wrong-type / upstream-500 || the ERROR line carries `content-type=`, `length=`, the response header NAMES and `body=` (≤ 512 printable bytes of ≤ 4 KiB read, non-printables escaped, `…(+N bytes)` when cut; the GW-REDACT formatter scrubs the rendered line) — the live-canary capture at the "upstream response received" boundary (spike §Recorded live protocol experiment; the first ride, 2026-10-22 21:54Z, answered 200 non-SSE and the log said only "upstream 200") | — | 1 |
| "an auth refusal's body is never read, not even into the log" | upstream-401 (a marker in the body) || the ERROR line says `<not read: auth>`; the marker appears in no log line | — | 1 |
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
| "a consumer that stops after the terminal event keeps the terminal outcome ⚖" | the consumer stops right after the completed event while the upstream still holds the stream open (the live native CLI's shape — 2026-10-22 22:57Z: both requests of the first completed canary turn were recorded `cancelled` / 499 with their usage counted) || completed, usage 7 / 3 | the event | 1; the trailer is never pulled |

### Named gaps and local evidence

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: SIWC profile (unselected)" | SIWC credentials || unsupported | separate grant and tool-shape contract required |
| "⚑ gap: live vendor header compatibility" | real native backend || offline round trip only | live canary must establish whether other headers are required |
| "⚑ gap: the live canary" | a real account || never run | spike step 4 — a separately authorized maintenance window |
| "⚖ local evidence: the pinned Codex CLI completes a turn through this gateway" | `experiments/codex-rail/compat.py` (codex-cli 0.161.0, the agent-runtime lock) || a completed `codex exec --json` turn, one rotation, one upstream close | not CI: the CLI is not in the CI toolchain — dated local evidence in `experiments/codex-rail/evidence.json` |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-RAIL-CODEX.md"

</details>

## GW-CODEX-HEADROOM

The rail is admitted on **account headroom**, held by the gateway itself (no Prometheus read,
ADR-108): one immutable snapshot of normalised windows, replaced only by a **strictly newer**,
valid report. The report schema is the gateway's own (`headroom.report` in the schema), not a
vendor payload; a producer must be authenticated and account-bound. Two producers exist today, both
the gateway's own and account-bound by construction — the usage poll (§Poll) and the headroom
headers of every relayed answer (§Upstream headers); a third, the jail's own `rate_limits` report,
is a `⚑ gap`. A fresh gateway answers `quota-unknown` until a report is accepted (fail closed). Freshness (`max_age_s`), the ceiling and the window profile are
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

### Poll

The gateway polls the account usage endpoint **itself** — the one credential owner observes its
own account (the operator ruling of 2026-10-19: the account is enrolled in the gateway, so no second
reader holds its token). Every `poll_interval_s` (policy, required, strictly below `max_age_s` so a
healthy schedule never goes stale — `policy-codex`: 30 s under 120 s ⚖; the deployed value is the
policy's) one `GET CODEX_USAGE_URL` (no default; unset = no poll, the rail stays `quota-unknown`)
goes out with `authorization: Bearer <access_token>` and `chatgpt-account-id`, through
`Lifecycle.acquire()` — so a poll inside the refresh margin rotates the credential exactly like a
request would, under the same lock. The answer is translated into the report above (`source:
poll`, `observed_at` = now): `rate_limit.limit_reached || !allowed` → `limited`; each of
`primary_window` / `secondary_window` → `{used_percent, resets_at: reset_at, window_minutes:
limit_window_seconds / 60}` (the native client's basis is the absolute `reset_at`, so is this
one's ⚖). A null window is **omitted**, which the profile check refuses whole — a missing window is
unknown, never zero. The payload shape is the 2026-10-22 observation (the spike §Live usage payload
shape; `tests/fixtures/codex-usage-observed.json` mirrors it with synthetic values); the identity
fields it carries (`account_id`, `email`, `user_id`) are never read, logged, attached or rendered.
Every outcome is counted on `gateway_codex_usage_poll_total{outcome}` ([GW-METRICS](metrics.md#gw-metrics)):
the family exists only while the policy DECLARES the codex rail (an undeclared rail renders no series,
so the silent-poll alert cannot fire on it) and then every outcome renders from 0; a refused or failed
poll leaves the last ACCEPTED report standing.

| description | the endpoint answers (world `policy-codex`, now T; the stored credential expires at T+1) || outcome | verdict after |
|---|---||---|---|
| "the observed shape is accepted, admits and renders the gauges" | 200, 20 % / 64 % (5h / 7d), allowed || accepted | admit — `gateway_subscription_utilization{rail="codex",window="5h"}` 0.2, `"7d"` 0.64 |
| "the poll rides the lifecycle: one owner rotates once, the rotated bearer and the account header go out ⚖" | 200 || accepted — the exchange ran once, the request carried the ROTATED bearer, `chatgpt-account-id`, `accept: application/json`; the store is `ready` | admit |
| "a missing window is refused whole — unknown, never zero ⚖" | 200, `secondary_window: null` || quota-invalid | quota-unknown |
| "a window outside the profile is refused" | 200, `limit_window_seconds: 86400` || quota-invalid | quota-unknown |
| "the vendor's limit flags limit" | 200, `limit_reached: true` / `allowed: false` || accepted | quota-limited |
| "a non-bool flag or a non-integer window field is refused" | 200, `allowed: 1` / `used_percent: 20.5` / `reset_at: "soon"` / `rate_limit: []` || quota-invalid | quota-unknown |
| "an upstream 401 is counted and changes nothing ⚖" | 401 after one accepted || upstream-auth (not a credential verdict — a usage 401 alone is no revocation evidence, spike §Refresh and headroom implications) | admit (the last accepted report stands) |
| "a 429 or 500 is an http error, nothing accepted" | 429 / 500 || upstream-http-error | quota-unknown |
| "an unreachable endpoint and a timeout are told apart" | connect error / read timeout || upstream-unreachable / upstream-timeout | quota-unknown |
| "a non-JSON, wrong-type or oversize body is refused ⚖" | `text/html`; `application/json` that is not JSON; 70 KiB (bound 64 KiB) || upstream-content-type | quota-unknown |
| "a store that does not answer is transient; a recovery marker is unresolved" | (the store) || credential-transient / credential-unresolved — the endpoint is never contacted | quota-unknown |
| "identity never leaves the poll" | 200 with DUMMY account / email / user ids || accepted — the report carries exactly `observed_at`, `source`, `limited`, `windows`; no log line at DEBUG carries an identity value | admit |
| "a dark rail has no poll" | no `CODEX_USAGE_URL`, or no credential backend || not enabled — a forced poll contacts nothing | quota-unknown |
| "the schedule polls at start, before the first interval ⚖" | `run()` || one poll before any sleep (a restart needs a fresh report) | admit |
| "poll_interval_s is required and sits below max_age_s" | policy `120` / `0` / absent / `true` (max_age_s 120) || PolicyError | — |
| "the counter's label set is the poll's outcome set" | — || `gateway_codex_usage_poll_total`'s `outcome` values = the poll's outcomes | — |
| "an undeclared rail renders no poll family; a declared one renders every outcome from 0 ⚖" | `GET /metrics` under `policy-default` (no codex rail) / under `policy-codex` (declared, nothing polled) || no `gateway_codex_usage_poll_total` series at all / the 11 outcomes, each 0 | — |

### Upstream headers

Every relayed 200 stream carries the account's windows as response headers — observed on the wire
2026-10-22 (the spike §The second ride): `x-codex-primary-used-percent`, `-window-minutes`,
`-reset-at`, the `secondary` set, and `x-codex-rate-limit-reached-type` when a limit is hit. The
gateway reads them at the "upstream response received" boundary, on the **relayed 200 only** (a
refused answer and a 429 are not read — the 429's verdict is its body's, and the next poll is at
most `poll_interval_s` away), and translates them into the report above (`source: upstream`,
`observed_at` = now; `limited` = the reached-type header present). The value grammar is the pinned
CLI's own reader (codex-rs `codex-api/src/rate_limits.rs` @ rust-v0.163.0): used-percent a float,
window-minutes and reset-at integers (epoch seconds), a window present iff its used-percent header
is ⚖ — a window with no used-percent header is OMITTED, which the profile check refuses whole
(unknown, never zero); a value the grammar cannot read is `quota-invalid`. The read never touches
the ride: the stream is relayed whole whatever the headers say, and a refused report leaves the
last accepted one standing. Both producers feed the ONE snapshot by the strictly-newer rule, so
they compete only by time — a poll in the same instant is `quota-out-of-order`. Every read is
counted on `gateway_codex_upstream_headroom_total{outcome}` ([GW-METRICS](metrics.md#gw-metrics)),
declared-gated like the poll family. Nothing else in the header set is read (plan type, credits,
the over-secondary percent, the safety flags).

| description | the relayed answer's headers (world `policy-codex`, admitted on a poll report 20 % / 64 % at T−10) || outcome | verdict after |
|---|---||---|---|
| "the relayed answer's windows are the second observation" | 30 % / 70 %, minutes 300 / 10080, resets T+900 / T+7000 || accepted | admit — the snapshot's `source` is `upstream`; `gateway_subscription_utilization{rail="codex"}` 0.3 / 0.7 |
| "the pinned CLI's value grammar ⚖" | `12.5` / `0`, integer minutes, epoch resets || accepted | admit — 0.125 / 0 (a float percent and a zero read as the CLI reads them) |
| "an answer without window headers is absent, the last report stands" | no `x-codex-*` window header || absent | admit — gauges 0.2 / 0.64 unchanged |
| "one window's headers alone are refused whole — unknown, never zero ⚖" | the primary set only || quota-invalid | admit (the poll's report stands) — the ride still 200 |
| "an unreadable value is refused and the ride is unaffected ⚖" | `lots` / `5h` / `soon` || quota-invalid | admit (unchanged) — the stream completes |
| "the reached-type header limits the next admission" | 30 % / 70 % + `x-codex-rate-limit-reached-type: primary` || accepted | quota-limited — the next `POST /sessions` defers `quota-limited` |
| "a window at the ceiling in the headers limits until its reset" | 96 % / 64 %, 5h resets T+1000 || accepted | quota-limited — defer, `retry_after_s` 1000 |
| "the two producers replace each other strictly by time ⚖" | headers at T; then a poll report at T, then one at T+1 || accepted; quota-out-of-order; accepted | admit — the newer poll's report |
| "only a relayed answer is read ⚖" | a 429 and a wrong-type 200 carrying exhausted windows || — (not read, nothing counted) | admit (unchanged) |
| "an undeclared rail renders no header family; a declared one renders every outcome from 0 ⚖" | `GET /metrics` under `policy-default` / `policy-codex` || no `gateway_codex_upstream_headroom_total` series / the 5 outcomes, each 0 | — |
| "the counter's label set is the reader's outcome set" | — || `gateway_codex_upstream_headroom_total`'s `outcome` values = the reader's outcomes | — |

### Gauges

An ACCEPTED report from either producer — and only one — sets the two subscription gauges of
[GW-METRICS](metrics.md#gw-metrics) for `rail="codex"`, one series per profile window:
`gateway_subscription_utilization` = `used_percent / 100`, `gateway_subscription_reset_seconds` =
`resets_at`. The `window` label is the profile's minutes spelled in the metrics vocabulary (300 →
`5h`, 10080 → `7d`) — the policy profile decides which series exist, and a profile minute the
vocabulary lacks renders `other` like any out-of-set label value ⚖. A refused report reaches no
gauge; a fresh gateway renders no codex series until a report is accepted (the headroom is
forgotten with the process — "a gateway restart forgets" above). The Grafana panels on UID
`claude-subscription` (the "Codex subscription (gateway headroom)" row) read these series.

| description | event (world `policy-codex`, now = 1800000000) || series | value |
|---|---||---|---|
| "an accepted report renders both gauges per window" | poll observed now−10, 20 % / 64 %, resets now+1000 / now+8000 — accepted || `gateway_subscription_utilization{rail="codex",window="5h"}` / `"7d"`; `gateway_subscription_reset_seconds{…}` | 0.2 / 0.64; 1800001000 / 1800008000 |
| "a refused report leaves the gauges unchanged ⚖" | …then an older report 99 % / 99 %, limited — refused `quota-out-of-order` || the same four series | 0.2 / 0.64; 1800001000 / 1800008000 (unchanged) |
| "a fresh gateway renders no codex series" | no report accepted || `gateway_subscription_*{rail="codex"}` | absent |

| description | profile minutes || `window` label on `rail="codex"` |
|---|---||---|
| "the window label is the profile's minutes in the window vocabulary ⚖" | 300, 10080, 1440, 90 || `5h`, `7d`, `other` (1440 → `1d` and 90 → `90m` are outside the vocabulary, bounded like any out-of-set value) |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: authenticated report ingress ⚖" | a jail `rate_limits` event || does not reach the gateway — §Poll and §Upstream headers are the producers | the token-gated jail ingest (spike §Candidate shape) |
| "⚑ gap: reservation" | two admissions at 94 % || both dispatched | reports do not meter concurrent use; the session cap is the only bound |

<details markdown="1"><summary>Evidence</summary>

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
exception chain or any repr. The durable store and seed recovery are specified below. The deployed policy declares the rail since 2026-10-22 (prober-only).

On the data plane a lifecycle failure answers before upstream is contacted:
`credential-store-unavailable` → 503 with `retry-after` (the store may answer next time); every
other code → 401 with that code (a durable state only an operator act changes). At admission the
durable state is read without refreshing: `ready` admits, `revoked` / `refreshing` skip the rail
(`credential-unresolved`), a store that does not answer is 503 `credential-transient`.

### Gateway-local durable ownership (operator ruling 2026-10-19)

`CODEX_UPSTREAM` plus `CODEX_SEED_FILE` wires SQLite and the native refresh transport.
The ESO-mounted seed is a JSON record with the four credential fields above. Infisical
holds only the seed; SQLite in `GATEWAY_DB` owns rotations. No write-back.
Each lock checks the mounted file's SHA-256; unchanged bytes are not decoded/imported again.
A changed valid seed atomically replaces record and hash, including a recovery marker.
A missing seed after import preserves the record. Invalid/oversized seeds fail closed.
⚖ Seed bound: 64 KiB. ⚖ A changed seed is also the recovery operation: it replaces a persisted
`refreshing` marker (the former "lost-rotation recovery", "production write-back" and "refresh
production wiring" gap rows close here — recovery is an operator re-seed with a fresh login,
never a gateway write-back). A POSIX file lock spans load/exchange/save; each SQLite FULL-synchronous
transaction commits independently so the marker survives process exit. Single replica,
Recreate on the PVC; distributed fencing remains FU-271. No credential memory fallback.

| description | sequence || result |
|---|---||---|
| "seed once" | empty database || ready |
| "seed unchanged is not imported again" | rotate, restart || rotation retained |
| "changed seed replaces ⚖" | rotate, replace seed (the record carries a `refreshing` marker) || new ready record — the marker is replaced too |
| "restart recovers state" | revoke, restart || revoked |
| "crash between exchange and save ⚖" | child exits in exchange || `refreshing` persists; `credential-recovery-required` until a changed seed |
| "memory fallback is refused" | :memory: || unavailable |

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
| "the deployed policy lists the subscription rails for every role ⚖" | `argocd/resources/agent-gateway/policy.json` || `rails.codex` with its `headroom` and `oauth` blocks (lit 2026-10-22, FU-270: the seed minted in #2826, the poll in #2828); every role's `rails` holds `anthropic`, `opencode` AND `codex` (operator ruling 2026-10-23: subscriptions go to all roles, the per-role order is the weekly knob — [GW-SESSIONS-ADMIT §The harness follows the rail](sessions.md#the-harness-follows-the-rail)); the metered `openrouter` rail, where listed, walks LAST — except for the `prober`, whose probes are that rail's | — |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: cross-process fencing" | two gateway replicas || one replica only (ADR-139) | distributed fencing — FU-271 |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CODEX-OAUTH.md"

</details>


## GW-CODEX-REFRESH

The native Codex refresh transport is an injectable callable for [GW-CODEX-OAUTH](#gw-codex-oauth),
not a login/import operation and not the SIWC token-sharing profile. It is not wired into production.
The [profile investigation](../../../docs/spikes/codex-subscription-rail.md#upstream-profile-investigation--2026-10-17-fu-270)
explains why these profiles must stay separate (FU-270).

> **External:** native implementation — [OpenAI Codex rust-v0.161.0 · auth manager § request_chatgpt_token_refresh](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/login/src/auth/manager.rs#L1627)
> **External:** native implementation — [OpenAI Codex rust-v0.161.0 · auth manager § should_refresh_proactively, access JWT exp](https://github.com/openai/codex/blob/979011409de0a60b52f179721948e65531d26144/codex-rs/login/src/auth/manager.rs#L2999)

One POST goes to `https://auth.openai.com/oauth/token`, JSON containing only `grant_type`,
`client_id` (the native public client id) and the stored `refresh_token`. No resource, scope,
access bearer or inbound headers are sent. TLS verification is on; ambient proxies, redirects
and retries are off. Connect/read/write/pool timeouts are each 10 seconds (per operation, not
an overall deadline). Response bytes are bounded to 64 KiB; encoded responses are refused. ⚖ These
bounds and refusing unknown token shapes are gateway policy, not vendor limits.

A successful exchange requires a fresh access JWT with a finite future `exp`. This claim is
used only for refresh scheduling, not verified identity; no guessed TTL is substituted for an
opaque or malformed token. The enrolled account id is preserved; if the access JWT supplies
`https://api.openai.com/auth.chatgpt_account_id`, it must match. An omitted refresh token retains
the old one (as the native client does); a present empty/null/malformed token fails closed.
ID tokens are not used for login or enrolment by this adapter.

A JSON 401, or JSON 400 with `invalid_grant`, `refresh_token_expired`, `refresh_token_reused` or
`refresh_token_invalidated` (case-insensitive, string `error` or nested `error.code`) is definitive:
the lifecycle persists `revoked`. Every other failure is uncertain, including malformed/oversized
responses, redirects, 429, 5xx, timeouts, invalid replacement and account mismatch. ⚖ Unlike the
native CLI's transient retry, the gateway keeps `refreshing` and requires recovery, because it
cannot rule out a lost rotation. Exceptions expose fixed text and no upstream exception chain.

World: [policy-codex · native-refresh](../worlds/README.md#the-codex-rails-fakes-tests_codex_worldpy),
HTTP fake reached through the real transport adapter and lifecycle; no live credentials.

| description | token endpoint response || first acquire | durable state | HTTP attempts across two acquires |
|---|---||---|---|---|
| "invalid grant stops refresh permanently" | 400 invalid_grant || credential-revoked | revoked | 1 |
| "reused rotation stops refresh permanently" | 400 nested refresh_token_reused || credential-revoked | revoked | 1 |
| "unauthorized refresh stops permanently" | 401 JSON || credential-revoked | revoked | 1 |
| "rate limit is uncertain and never retried ⚖" | 429 || credential-refresh-uncertain | refreshing | 1 |
| "redirect never sends the refresh token elsewhere" | 302 with Location || credential-refresh-uncertain | refreshing | 1 |
| "unknown expiry never gets a guessed lifetime ⚖" | 200 opaque access token || credential-refresh-uncertain | refreshing | 1 |
| "different account cannot replace the enrolled account" | 200 other account claim || credential-refresh-uncertain | refreshing | 1 |

| description | response || saved before return | expiry |
|---|---||---|---|
| "rotation is saved before use" | fresh access JWT and replacement refresh token || both replacements, ready | JWT exp |
| "omitted refresh token retains the stored token" | fresh access JWT only || replacement access and stored refresh, ready | JWT exp |

<details markdown="1"><summary>Evidence — latest run</summary>

--8<-- "GW-CODEX-REFRESH.md"

</details>
