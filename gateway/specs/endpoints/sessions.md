---
id: EP-SESSIONS
use-cases: [UC-1]
schema: sessions.schema.json
---
# POST /sessions · GET /sessions/{id} · DELETE /sessions/{id} — the launcher's one question

*May this unit run now, with which harness, and what goes in the pod's env.* The control-plane
seam of the island ([UC-1](../use-cases/uc-1-worker-ride.md) steps ① and ④). The caller sends
`(stack, role, task, round)` and optional `tier` / `harness` / `rail`; the gateway answers
`dispatch` (a session, a rail, a harness, a model, the pod's complete LLM env) or `defer` (a
typed reason and when to ask again). No caller names a model: the policy does, and every
data-plane request is resolved from the session identity
([GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve)).

## Interface — the machine half

**[`sessions.schema.json`](sessions.schema.json)** is the single source for the request,
response and error shapes; the service **imports it**. Coupling is enforced by
`scripts/spec_gate.py` in `devbox run ci` (rule 7).

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-SESSIONS-ADMIT](#gw-sessions-admit) | `post.input`, `post.output` (`dispatch` / `defer`) | `malformed-body`, `harness-rail-mismatch`, `credential-transient` | v0 — the ADR-096 ladder, the FU-088 window latches / headroom polling and the capacity doorbell are `⚑ gap` (rows below); `/route` compatibility is `⚑ gap` (not served; consumers move to this endpoint) |
| [GW-SESSIONS-ENV](#gw-sessions-env) | `post.output.dispatch.env`, `post.output.dispatch.context_tokens` | — | v0 for `claude` / `opencode` / `goose`; `codex` harness `⚑ gap` (no codex rail, no codex env today) |
| [GW-SESSIONS-TOKEN](#gw-sessions-token) | `post.output.dispatch.session`, `get.output` | `session-not-found` | v0 |
| [GW-SESSIONS-RELEASE](#gw-sessions-release) | `delete.output`, `get.output.released_at` | `session-not-found` | v0 |
| [GW-CRED-RESOLVE](#gw-cred-resolve) | `post.output.defer.reason` (`credential-unresolved`) | `credential-transient` | v0 |
| [GW-REDACT](#gw-redact) | `$defs.error_envelope.error.message` (the one wire surface a log-shaped string reaches) + log lines (a formatter invariant) | — | v0 |
| [GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve) (owned there) | `post.output.dispatch.model` | — | linked — the model a dispatch names is the one every data-plane request must carry |
| [GW-ACCESS](../access.md#gw-access) (owned there) | `post.input.role` | — | linked — the role's rail set is the inventory's enforced column |

Rows below run against the **`policy-default` world**
([worlds/policy-default.json](../worlds/policy-default.json)) with `FakeSecrets` holding every
ref the policy names unless a row says otherwise; the canonical end-to-end pair lives in
[`uc-1/request.json`](../use-cases/uc-1/request.json) → [`uc-1/expected-response.json`](../use-cases/uc-1/expected-response.json).

## GW-SESSIONS-ADMIT

A `POST /sessions` body is admitted by walking `roles.<role>.rails` in order and picking the
**first rail** whose `active_sessions < rails.<rail>.max_sessions` AND whose credential for
the stack resolves ([GW-CRED-RESOLVE](#gw-cred-resolve)). None → `defer`. The walk is filtered
by the harness first: `claude` speaks the anthropic dialect (rails `anthropic`, `opencode`);
`opencode` / `goose` / `codex` speak openai (rails `openrouter`, `opencode`); a rail the harness
cannot speak is skipped, and an **explicit** `harness` × `rail` pair that cannot speak is a 400
`harness-rail-mismatch`, never a silent skip. `defer` is HTTP 200 — a normal answer the caller
polls after `retry_after_s`; only a malformed body or a transient credential fault is an HTTP
error. ⚖ v0 admits on count and credential only: no window utilization, no strikes, no
cooldowns, no provider pins — the ADR-096 ladder is a gap, rendered as rows, not omitted.

### Which rail, or why not

| description | role | harness | tier | active on rails (anthropic / opencode / openrouter) | credential state || decision | rail | model | reason |
|---|---|---|---|---|---||---|---|---|---|
| "a worker takes the first rail in its list" | worker | (policy: opencode) | (policy: standard) | 0 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/deepseek-v4-flash | — |
| "the first rail is full, the second is taken" | worker | (policy) | (policy) | 0 / 3 / 0 | all resolve || dispatch | openrouter | deepseek/deepseek-v4-flash | — |
| "every allowed rail is full" | worker | (policy) | (policy) | 0 / 3 / 20 | all resolve || defer | — | — | rail-capacity |
| "a reviewer rides the subscription first" | reviewer | (policy: claude) | (policy: heavy) | 0 / 0 / 0 | all resolve || dispatch | anthropic | claude/sonnet | — |
| "the subscription is full, the reviewer takes Go" | reviewer | (policy) | (policy) | 5 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/claude-sonnet-4-6 | — |
| "the stack's anthropic ref does not resolve, the walk continues ⚖" | reviewer | (policy) | (policy) | 0 / 0 / 0 | anthropic_ref definitive miss || dispatch | opencode | opencode-go/claude-sonnet-4-6 | — |
| "the only allowed rail's credential does not resolve" | prober | (policy) | (policy) | 0 / 0 / 0 | anthropic_ref definitive miss || defer | — | — | credential-unresolved |
| "an explicit tier picks the model inside the rail" | worker | (policy) | heavy | 0 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/claude-sonnet-4-6 | — |
| "an explicit harness narrows the walk to its dialect" | worker | goose | (policy) | 0 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/deepseek-v4-flash | — |
| "a harness that cannot speak the role's only rail ⚖" | prober | opencode | (policy) | 0 / 0 / 0 | all resolve || defer | — | — | role-rail-denied |
| "an explicit rail the role is not allowed" | worker | (policy) | (policy) | 0 / 0 / 0 | all resolve, `rail: anthropic` || defer | — | — | role-rail-denied |
| "an explicit rail the role is allowed is taken even when later in the list (logged as an override) ⚖" | worker | (policy) | (policy) | 0 / 0 / 0 | all resolve, `rail: openrouter` || dispatch | openrouter | deepseek/deepseek-v4-flash | — |
| "an unknown stack" | worker (stack `nope`) | (policy) | (policy) | 0 / 0 / 0 | — || defer | — | — | stack-unknown |

### What is an HTTP error, and what is not

| description | body || status | error code |
|---|---||---|---|
| "a well-formed request that must wait" | worker, every rail full || 200 | — (`decision: defer`) |
| "a missing required field" | no `task` || 400 | malformed-body |
| "a role outside the enum" | `role: janitor` || 400 | malformed-body |
| "a tier outside the enum" | `tier: enormous` || 400 | malformed-body |
| "a negative round" | `round: -1` || 400 | malformed-body |
| "an explicit harness and rail that cannot speak" | `harness: claude`, `rail: openrouter` || 400 | harness-rail-mismatch |
| "an explicit harness and rail that can speak" | `harness: claude`, `rail: opencode` (reviewer) || 200 | — (`decision: dispatch`) |
| "the kube API is away while resolving the credential" | reviewer; `FakeSecrets` transient fault || 503 | credential-transient |

### Counting

| description | before || active after | `gateway_sessions_active{rail}` |
|---|---||---|---|
| "a dispatch counts on its rail" | opencode 0 → worker dispatched || opencode 1 | opencode = 1 |
| "a release frees the slot" | opencode 1 → `DELETE` it || opencode 0 | opencode = 0 |
| "an expiry frees the slot without a DELETE" | opencode 1, `expires_at` passed || opencode 0 | opencode = 0 |
| "a defer counts nothing" | opencode 3 → worker deferred || opencode 3 | opencode = 3 |

### Named gaps (rows that exist so the omission is visible)

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: the subscription's 5h/7d window is near its cap" | reviewer, anthropic 0/5 but window at 0.95 || dispatch on anthropic | FU-088 latches / headroom polling — v0 counts sessions only |
| "⚑ gap: a model struck on this task last round" | worker, round 2 after a strike || the policy model, unchanged | ADR-096 strikes / cooldowns / pair holds |
| "⚑ gap: labels, urgency, budget class" | body carries none, none read || — | the ADR-096 ladder's inputs; `tier` is the only size knob |
| "⚑ gap: `POST /route`" | any || 404 | not served by this gateway — consumers move to `/sessions`; the old proxy keeps serving it |
| "⚑ gap: a capacity doorbell" | a rail frees a slot || nothing is pushed | the caller polls `retry_after_s` |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI (`evidence/evidence.json`, stamped `image
digest · date`); unrendered here = unverified.

--8<-- "GW-SESSIONS-ADMIT.md"

</details>

## GW-SESSIONS-ENV

A `dispatch` answer carries `env`: the pod's **complete** LLM environment for that harness,
pointing at THIS gateway with the session token as the credential — the launcher copies it
verbatim and adds nothing LLM-shaped. Var names mirror what each harness consumes today
(`agents/agent-session.sh`): `claude` reads `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`
(rendered there today) and `ANTHROPIC_MODEL` (the name the CLI needs; the gateway rewrites
anyway). ⚖ For `opencode` and `goose` the brief prescribes `OPENAI_BASE_URL` / `OPENAI_API_KEY`
+ a model var, while the launcher today feeds goose through `GOOSE_PROVIDER=openrouter` +
`GOOSE_MODEL` + `OPENROUTER_HOST` and opencode through an `OPENCODE_CONFIG` file
(`provider.openrouter.options.baseURL` + `apiKey: {env:OPENROUTER_API_KEY}`) — the two do not
agree, so the openai-dialect rows below carry the brief's names and are flagged **verify during
implementation**: a harness that ignores a var the gateway hands it is a failed row, not a
passed one. The model var carries the policy id with its rail prefix removed (`claude/sonnet` →
`sonnet`, `opencode-go/deepseek-v4-flash` → `deepseek-v4-flash`; openrouter ids are bare) — the
same strip `agents/agent-session.sh` performs today. `context_tokens` is the policy's per-model
window or `null` — a null is "not declared", never a guess.

| description | harness | rail | model (policy) || env var | value |
|---|---|---||---|---|
| "claude: the base url is this gateway's anthropic path" | claude | anthropic | claude/sonnet || `ANTHROPIC_BASE_URL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/anthropic` |
| "claude: the auth token is the session token" | claude | anthropic | claude/sonnet || `ANTHROPIC_AUTH_TOKEN` | the session token |
| "claude: the model name is the alias the CLI resolves" | claude | anthropic | claude/sonnet || `ANTHROPIC_MODEL` | `sonnet` |
| "claude on the [Go rail](../../../docs/agents/chainless-redesign.md): same three vars, Go's model name" | claude | opencode | opencode-go/claude-sonnet-4-6 || `ANTHROPIC_MODEL` | `claude-sonnet-4-6` |
| "opencode: the base url is this gateway's openai path ⚖ (verify)" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENAI_BASE_URL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/openai/v1` |
| "opencode: the api key is the session token ⚖ (verify)" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENAI_API_KEY` | the session token |
| "opencode: the model var carries the bare id ⚖ (verify)" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENCODE_MODEL` | `deepseek-v4-flash` |
| "goose: the base url is this gateway's openai path ⚖ (verify)" | goose | openrouter | deepseek/deepseek-v4-flash || `OPENAI_BASE_URL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/openai/v1` |
| "goose: the api key is the session token ⚖ (verify)" | goose | openrouter | deepseek/deepseek-v4-flash || `OPENAI_API_KEY` | the session token |
| "goose: the model var carries the bare id ⚖ (verify)" | goose | openrouter | deepseek/deepseek-v4-flash || `GOOSE_MODEL` | `deepseek/deepseek-v4-flash` |

| description | harness || vars present | vars absent |
|---|---||---|---|
| "claude's env is exactly three vars" | claude || `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` | `ANTHROPIC_API_KEY`, any `OPENAI_*`, any `OPENROUTER_*` |
| "the openai-dialect env never carries an anthropic var" | opencode || `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENCODE_MODEL` | any `ANTHROPIC_*`, `OPENROUTER_API_KEY` |
| "no env value is a real key" | any || every value is the token, a URL or a model name | any value matching the [GW-REDACT](#gw-redact) patterns |
| "⚑ gap: codex" | codex || — | no env table — the codex harness/rail is out of v0; `harness: codex` is a 400 `harness-rail-mismatch` against every rail until a row says otherwise |

| description | model (policy) || `context_tokens` |
|---|---||---|
| "a declared `context_tokens` is echoed" | opencode-go/deepseek-v4-flash || 1000000 |
| "an undeclared `context_tokens` is null, never a default" | claude/sonnet || null |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-ENV.md"

</details>

## GW-SESSIONS-TOKEN

The session token is `gws_` + 32 url-safe random characters, minted from a CSPRNG once per
dispatch and returned **once** — in the `dispatch` body. The DB stores `sha256(token)` and never
the token; `GET /sessions/{id}` returns the row without it. The data plane accepts the token as
`Authorization: Bearer gws_…` or `x-api-key: gws_…` ([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary)).
`expires_at = created_at + session_ttl_s`.

| description | action || result |
|---|---||---|
| "the token has the fixed shape" | dispatch || `token` matches `^gws_[A-Za-z0-9_-]{32}$` |
| "two dispatches never share a token" | dispatch twice || tokens differ |
| "the row holds a hash, not the token" | dispatch, read the DB || `token_hash` = sha256 hex of the token; no column equals the token |
| "GET returns the row without the token" | dispatch → `GET /sessions/{id}` || 200; `id, stack, role, task, round, rail, harness, model, created_at, expires_at, released_at, requests, tokens_in, tokens_out`; no `token`, no `token_hash` |
| "GET on an unknown id" | `GET /sessions/nope` || 404 `session-not-found` |
| "expiry is the policy TTL" | dispatch at T || `expires_at` = T + 14400 s (`policy-default`) |
| "a request through the data plane is counted on the row" | dispatch → one `upstream-ok` call → GET || `requests` = 1, `tokens_in`/`tokens_out` = the upstream `usage` (`tokens_in` = uncached input; the cache classes in `tokens_cache_read`/`tokens_cache_write` — GW-METRICS) |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-TOKEN.md"

</details>

## GW-SESSIONS-RELEASE

`DELETE /sessions/{id}` is the launcher's finalize hook: it stamps `released_at`, frees the
rail slot, and from that moment the token is refused on the data plane with 401
`session-released`. An expired session is refused with 401 `session-expired` without any
DELETE. Release is idempotent — a second DELETE answers 200 with the same `released_at`.

| description | session state | action || status | result |
|---|---|---||---|---|
| "release an active session" | active | DELETE || 200 | `released_at` set; `gateway_sessions_active{rail}` − 1 |
| "release twice" | released | DELETE || 200 | same `released_at`, no second decrement |
| "release an unknown id" | — | DELETE `/sessions/nope` || 404 | session-not-found |
| "a released token on the data plane" | released | `POST /openai/v1/chat/completions` || 401 | session-released |
| "an expired token on the data plane" | expired | `POST /anthropic/v1/messages` || 401 | session-expired |
| "an expired session releases its slot" | expired, no DELETE | admission walk || — | the slot counts as free |
| "release of an expired session" | expired | DELETE || 200 | `released_at` set; the data-plane verdict stays `session-expired` ⚖ (expiry is the older fact) |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-RELEASE.md"

</details>

## GW-CRED-RESOLVE

A credential ref (`namespace/name`) is resolved by reading the Secret through the gateway's
ServiceAccount (`/var/run/secrets/kubernetes.io/serviceaccount`). The read is a verdict in
three classes: **resolved** (the Secret exists, carries the label
`openrouter.teststuff.net/session-key=true`, and the rail's key is present), **definitive miss**
(404, 403, the label absent, the key absent — the ref is wrong), **transient** (5xx or the API
unreachable — nothing is known about the ref). Resolved values are cached 300 s; misses 20 s.
Per rail: `anthropic` → `stacks.<stack>.anthropic_ref`, key `AUTH_TOKEN`; `openrouter` →
`stacks.<stack>.openrouter_ref`, key `OPENROUTER_API_KEY`; `opencode` → the gateway's **own**
mounted Secret (`agent-egress/opencode-go-key`, key `api-key`, env `OPENCODE_GO_API_KEY`) — no
kube read, no per-stack ref. The precedent is the old proxy's `_resolve_ref` (homelab#1004
negative TTL, homelab#1620 transient class); RBAC is a Role per loop namespace granting `get`
on secrets to the gateway SA.

| description | rail | the Secret read returns || verdict | admission | data plane | `gateway_credential_resolve_total{rail,outcome}` |
|---|---|---||---|---|---|---|
| "a labeled Secret with the rail's key" | anthropic | 200, label true, `AUTH_TOKEN` present || resolved | eligible | served | anthropic, resolved |
| "a labeled Secret with the rail's key" | openrouter | 200, label true, `OPENROUTER_API_KEY` present || resolved | eligible | served | openrouter, resolved |
| "the Secret is missing" | openrouter | 404 || definitive | skipped (defer `credential-unresolved` if last) | 401 `credential-unresolved` | openrouter, definitive |
| "RBAC refuses the read" | anthropic | 403 || definitive | skipped | 401 `credential-unresolved` | anthropic, definitive |
| "the Secret exists but is unlabeled" | anthropic | 200, no label || definitive (refused: not a session key) | skipped | 401 `credential-unresolved` | anthropic, definitive |
| "the Secret is labeled but the rail's key is absent" | openrouter | 200, label true, only `AUTH_TOKEN` || definitive | skipped | 401 `credential-unresolved` | openrouter, definitive |
| "the API server fails" | anthropic | 503 || transient | 503 `credential-transient` | 503 `credential-transient` | anthropic, transient |
| "the API server is unreachable" | openrouter | connection refused / timeout || transient | 503 `credential-transient` | 503 `credential-transient` | openrouter, transient |
| "the Go key is the gateway's own mount" | opencode | (no read) || resolved from `OPENCODE_GO_API_KEY` | eligible | served | opencode, resolved |
| "the Go mount is empty" | opencode | (no read), env unset || definitive | skipped | 401 `credential-unresolved` | opencode, definitive |

| description | sequence || kube reads | reason |
|---|---||---|---|
| "a resolved ref is cached" | resolve, resolve again within 300 s || 1 | positive TTL 300 s |
| "a positive entry expires" | resolve, advance 301 s, resolve || 2 | positive TTL elapsed |
| "a miss is cached briefly" | 404, resolve again within 20 s || 1 | negative TTL 20 s |
| "a miss expires fast" | 404, advance 21 s, resolve || 2 | negative TTL elapsed — a transient blip never poisons the window |
| "a transient never poisons a stack's other rail ⚖" | anthropic transient, then openrouter || the openrouter read happens | verdicts are per ref |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CRED-RESOLVE.md"

</details>

## GW-REDACT

No log line the gateway emits contains a credential value: a bearer value, a `gws_` token, an
`sk-ant-oat…` OAuth token, an `sk-or-v1-…` OpenRouter key, or the Go key's value. The log
formatter replaces any such substring with `<redacted>` before the line is written, whatever
the call site passed — the precedent is the old proxy's `_looks_like_credential`. A test row
feeds each pattern through the formatter directly; a second set proves the formatter is on the
real paths (an upstream 401 body, a malformed header, a debug line of the resolved ref).

| description | the formatter is given || the line contains | the line does not contain |
|---|---||---|---|
| "a session token in a message" | `"auth ok gws_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"` || `auth ok <redacted>` | `gws_` |
| "an OAuth token" | `"inject sk-ant-oat01-FAKE…"` || `inject <redacted>` | `sk-ant-oat` |
| "an OpenRouter key" | `"inject sk-or-v1-FAKE…"` || `inject <redacted>` | `sk-or-v1-` |
| "a bearer header value" | `"Authorization: Bearer abc.def.ghi"` || `Authorization: Bearer <redacted>` | `abc.def.ghi` |
| "the Go key's value" | the `OPENCODE_GO_API_KEY` fixture value || `<redacted>` | the value |
| "a ref is not a credential" | `"ref platform-agents/claude-session unresolved"` || the ref verbatim | `<redacted>` |
| "a model id is not a credential" | `"model opencode-go/deepseek-v4-flash"` || the id verbatim | `<redacted>` |

| description | path || the log holds | the log does not hold |
|---|---||---|---|
| "an upstream 401 body is summarised, not copied" | `upstream-401` on openrouter || `upstream-auth openrouter 401` | the upstream body, the key |
| "a bad inbound header is logged by shape" | `Authorization: Bearer notatoken` || `session-unknown` | `notatoken` |
| "a dispatch line names the session id, never the token" | dispatch || the session id | the token |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-REDACT.md"

</details>
