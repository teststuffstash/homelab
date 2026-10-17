# worlds/ — named fixture states

A **world** is a named, human-readable fixture state: expected behaviour is a function of
(system, world), so a row that does not name its world is lying by omission. For the gateway a
world has two halves — a **policy document** and an **upstream behaviour** — and a row names
both when a requirement's evidence spans more than one of either (`"policy-default · upstream-429: …"`);
a single-world module declares it once in its docstring and omits it from row ids.

## Policy worlds

| world | file | what it is |
|---|---|---|
| `policy-default` | [policy-default.json](policy-default.json) | the test policy: two stacks (`platform`, `oracle`), all seven roles, three rails with the model ids copied from `model-classes.json`; caps small enough to fill in a test (`anthropic` 5, `opencode` 3, `openrouter` 20); the anthropic rail's `side_models` = `claude/haiku` (claude-code's side-call family, [GW-MODEL-RESOLVE](../endpoints/anthropic-messages.md#gw-model-resolve) ⚖); `control_plane_auth: observe` with three fixture `callers` (the platform loop, the specs reviewer — [GW-SESSIONS-AUTH](../endpoints/sessions.md#gw-sessions-auth) — and a judge, `outcome: any`, [GW-SESSIONS-OUTCOME](../endpoints/sessions.md#gw-sessions-outcome)), so a row that sends no caller token is admitted; `outcome_window_s` 86400; the per-rail header and recovery keys: `user_agent` (`forward` on anthropic and openrouter, `fixed` on opencode) and `credential_probe` (opencode: `POST /v1/chat/completions`, 1 token on its light model; openrouter: `GET /v1/key`; anthropic none, so `credential_hold_s` defaults to 900) — [§Capacity](../endpoints/sessions.md#capacity--the-ladders-capacity-half) |
| `policy-enforce` | [policy-enforce.json](policy-enforce.json) | `policy-default` with `control_plane_auth: enforce` and nothing else changed — for the GW-SESSIONS-AUTH enforce rows only |
| `policy-codex` | [policy-codex.json](policy-codex.json) | `policy-default` plus the codex rail (`max_sessions` 2, the fixture model `codex/fixture-model`, `headroom` 120 s / 0.95 / the 300- and 10080-minute windows, `oauth.refresh_margin_s` 30) that only `prober` may ride — for the codex rows only; the deployed policy declares no codex rail |

Names in the test policy (namespaces, Secret names) are **fixture names**, not production
ones; the production policy is the ConfigMap in `argocd/resources/agent-gateway/`. Model ids
are the exception: they are copied verbatim from
`argocd/resources/openrouter-proxy/model-classes.json` (`models.*.ids` per rail, the `coding`
class's `chain_head` order) so the fixture never names a model the fleet does not run. The one
exception to the exception: `policy-codex`'s `codex/fixture-model` — the fleet runs no codex model
yet, and choosing a representative one is the design session's call, not a fixture's ⚖.

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
| `upstream-429-reset` | OpenRouter's 429 shape (the 2026-10-17 tap): `x-ratelimit-limit: 20`, `-remaining: 0`, `-reset` = the row's epoch **milliseconds**, no `retry-after` (a row may add one), body `limit_source: openrouter_free_tier_per_minute` | the cell-cooldown rows ([§Capacity](../endpoints/sessions.md#capacity--the-ladders-capacity-half)) |
| `upstream-401` | 401 with a body mentioning the key | 424 `upstream-auth`, body never forwarded; the credential rejected |
| `upstream-401-key-expired` | 401 `{type: authentication_error, code: api_key_expired}` — the Go vendor's live answer to an expired key (the 2026-10-17 tap) | 424 `upstream-auth` on the opencode rail |
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
