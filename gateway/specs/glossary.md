# Glossary — the gateway's ubiquitous language

One definition per term — a decision table where the term encodes rules, prose where it names a
thing; other pages reference terms instead of repeating definitions. Platform-wide terms
(stack, role, AgentStack claim, loop namespace, Go rail) keep their homelab definitions in
[`docs/glossary.md`](../../docs/glossary.md); this file defines only what the gateway coins or
narrows.

## island

A directory inside the homelab monorepo with its own build, specs, tests and context
([context-and-autonomy.md §Direction 1](../../docs/spikes/context-and-autonomy.md)). The
gateway is the first one (P2). An island exposes what its consumer needs to act, not what the
island holds — the seam here is [`POST /sessions`](endpoints/sessions.md) plus the two
data-plane dialects.

## session

The unit of admission: one `(stack, role, task, round)` ride, admitted by
[`POST /sessions`](endpoints/sessions.md), identified by a **session token** on every data-plane
request, and ended by `DELETE /sessions/{id}` or expiry. A session pins exactly one rail, one
harness and one model for its whole life. The DB row holds the token's sha256, never the token.

| state | how it is entered | data-plane verdict |
|---|---|---|
| active | `decision: dispatch` | served (a bound session: once its env is pulled — no token exists before) |
| released | `DELETE /sessions/{id}` | 401 `session-released` |
| expired | `expires_at` passed (created_at + policy `session_ttl_s`) | 401 `session-expired` |

## session token

`gws_` + 32 url-safe random characters, minted once per session, returned once (in the
`dispatch` response — or, for a [bound](#bind) session, in its [env pull](#env-pull)) and carried
by the pod as its only LLM credential. Worthless outside the
cluster: it resolves only at this gateway.

## bind

The pod identity a session's env may be pulled by — `{namespace, serviceaccount, pod?}` in a
`POST /sessions` body ([GW-SESSIONS-PULL](endpoints/sessions.md#gw-sessions-pull)). A bound
session's dispatch answer carries no token and no env values; the gateway compares the bind with
a TokenReview of the pod's projected ServiceAccount token. Not a Kubernetes RoleBinding.

## env pull

`POST /sessions/{id}/env`: the bound pod presents its projected ServiceAccount token (audience
`agent-gateway`) and receives its LLM env, carrying a session token minted at that moment — at
most once per session ([GW-SESSIONS-PULL](endpoints/sessions.md#gw-sessions-pull)). The launcher
never holds the token; credential writes stay with the gateway.

## rail

A billing/credential lane upstream. v0 has four (one dark); each has one upstream host, one
credential source and one `max_sessions` cap in the policy.

| rail | credential | upstream host | dialects served |
|---|---|---|---|
| `anthropic` | the operator's Claude subscription OAuth token (`AUTH_TOKEN` in the stack's `claude-session` Secret) | `api.anthropic.com` | anthropic |
| `opencode` | the OpenCode Go subscription key (the gateway's own mounted Secret) | `opencode.ai/zen/go` | anthropic, openai |
| `openrouter` | the per-stack OpenRouter key minted by openrouter-operator | `openrouter.ai/api/v1` | anthropic, openai |
| `codex` (**dark**) | the operator's ChatGPT subscription OAuth record, behind the persistence interface — FAKE store only, no production write-back ([GW-CODEX-OAUTH](endpoints/openai-responses.md#gw-codex-oauth)) | unselected (`CODEX_UPSTREAM`, no default) | responses |

Out of v0 and named only as gaps: `zen`.

## dialect

The wire format of an LLM request — which inbound path the pod speaks and which upstream
endpoint shape it maps to. `anthropic` = Anthropic Messages (`/anthropic/v1/messages`);
`openai` = OpenAI Chat Completions (`/openai/v1/chat/completions`, plus `GET /openai/v1/models`);
`responses` = OpenAI Responses over SSE (`/openai/v1/responses` — streaming, `store: false`).
A harness speaks exactly one dialect; a rail serves one or both (table under *rail*).

## harness

The agent CLI the pod runs: `claude`, `opencode`, `goose`, `codex` (its rail ships dark). The
harness fixes the dialect (`claude` → anthropic; `opencode`/`goose` → openai; `codex` → responses) and the
set of env var names the gateway must hand the pod
([GW-SESSIONS-ENV](endpoints/sessions.md#gw-sessions-env)).

## credential ref

A `namespace/name` pointer to a Kubernetes Secret, written in the policy (`anthropic_ref`,
`openrouter_ref`), resolved by the gateway through its ServiceAccount
([GW-CRED-RESOLVE](endpoints/sessions.md#gw-cred-resolve)). A ref names a credential; it is
never one — a pod sees refs' *effects* (a session token), never a ref and never a value. The
Secret must carry the label `openrouter.teststuff.net/session-key=true`, else the ref refuses.

## policy

The gateway's one configuration document, `/etc/agent-gateway/policy.json` (a ConfigMap,
homelab config; the test world is [worlds/policy-default.json](worlds/policy-default.json)):
per-stack credential refs, per-role allowed rails in preference order with a default tier and
harness, per-(rail, tier) ordered model list, per-rail `max_sessions` and `side_models` (the families a
harness's side-calls may name on any session of that rail), per-model `context_tokens`,
`session_ttl_s`. **No model id lives in code** — only here, copied from
`argocd/resources/openrouter-proxy/model-classes.json`; the deployed policy
(`argocd/resources/agent-gateway/policy.json`, the source of the `agent-gateway-policy`
configMapGenerator) has the same shape and is loaded by a
test row.

## tier

A size label on a session — `light` | `standard` | `heavy` — that selects the model within the
chosen rail: `rails.<rail>.models.<tier>`, an ORDERED list the walk takes the first admissible
model of (not struck by this task, not cooled; a bare string = a one-item list —
[§The retry contract](endpoints/sessions.md#the-retry-contract--model-lists-strikes-attempt)). The role's default comes from the policy; the caller
may override it. Not the ADR-096 model tier (`cheap`/`large`/`premium`), which is a gap.

## defer

The admission answer "not now": HTTP 200 `{decision: "defer", reason, retry_after_s}` — never
an HTTP error. Typed reasons: `rail-capacity`, `rail-window`, `rail-latched`, `cell-cooled`, `role-rail-denied`,
`stack-unknown`, `credential-unresolved`, `credential-rejected`, `cells-exhausted` (no
`retry_after_s`: every cell is struck for this task — escalate, do not poll), and the codex rail's headroom verdicts `quota-unknown`,
`quota-stale`, `quota-limited` ([GW-CODEX-HEADROOM](endpoints/openai-responses.md#gw-codex-headroom)).
The caller polls after `retry_after_s` — for a capacity-blocked rail, the moment the block lifts
([sessions.md §Capacity](endpoints/sessions.md#capacity--the-ladders-capacity-half)).

## cell

A (rail, model) pair — one model served on one rail, the unit an upstream 429 cools
([sessions.md §Capacity](endpoints/sessions.md#capacity--the-ladders-capacity-half)). ⚖ Narrower
than the old router's cell, which is (model, provider) and carries a price and a pin
([model-routing.md](../../docs/agents/model-routing.md)): the gateway pins no provider, so a
provider is evidence on a cell, not part of its key.

## headroom

The codex rail's account capacity as the gateway last saw it: one normalised snapshot of the
subscription's windows (used fraction, reset time) plus an explicit `limited` flag, replaced only
by a strictly newer valid report. Its verdict (`admit`, `quota-unknown`, `quota-stale`,
`quota-limited`) gates admission onto the rail
([GW-CODEX-HEADROOM](endpoints/openai-responses.md#gw-codex-headroom)); Prometheus observes it,
never decides it.

## persistence interface

The `Store` seam the codex OAuth lifecycle runs behind — `lock()` / `load()` / `save()`, one
account per store, the lock held across load → refresh → save, `save` atomic and durable
([GW-CODEX-OAUTH](endpoints/openai-responses.md#gw-codex-oauth)). Only a FAKE (process-memory)
implementation exists; the production one is a `⚑ gap`.

## control plane / data plane

Control plane = `/sessions` (admission, lookup, release), `/healthz`, `/metrics`. Data plane =
the two dialect paths the pod's LLM traffic rides. `/sessions` is called by launchers with their
projected ServiceAccount token, checked against the policy's `callers`
([GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth); `/healthz` and `/metrics` stay open,
in-cluster only); the data plane requires a session token.

## world

A named fixture state a row runs against: a policy document plus a fake-upstream behaviour
([worlds/README.md](worlds/README.md)). Row ids carry the world when a requirement's evidence
spans more than one.
