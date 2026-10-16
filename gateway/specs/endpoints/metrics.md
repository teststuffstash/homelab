---
id: EP-METRICS
use-cases: [UC-1]
schema: metrics.schema.json
---
# GET /metrics — the `gateway_*` families, with bounded labels only

The evidence surface the alert belts read. Six families, Prometheus text format, no auth
(in-cluster, scraped by the ServiceMonitor). **Every label value is drawn from a bounded set**
declared in the schema — never a task key, a session id, or a model string outside the
policy's set — so cardinality is a property of the policy, not of traffic.

## Interface — the machine half

**[`metrics.schema.json`](metrics.schema.json)** declares each family (name, type, labels and
the bounded value set per label); the service **imports it** to register the families, so a
label the schema does not declare cannot be emitted. No error codes: `/metrics` answers 200 or
the process is down.

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-METRICS](#gw-metrics) | `families.*` | — | v0 — the cost ledger / `/generation` USD harvest and the capacity-doorbell signal are `⚑ gap` (rows below) |
| [GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit) (owned there) | `families.gateway_sessions_active` | — | linked — the gauge IS the admission counter |
| [GW-CRED-RESOLVE](sessions.md#gw-cred-resolve) (owned there) | `families.gateway_credential_resolve_total` | — | linked — the `outcome` label is that requirement's verdict class |

## GW-METRICS

| family | type | labels | what it counts |
|---|---|---|---|
| `gateway_sessions_active` | gauge | `rail` | sessions neither released nor expired, per rail — the admission counter |
| `gateway_sessions_total` | counter | `rail`, `role`, `stack`, `decision` | every `POST /sessions` answer; `rail` = `none` on a defer ⚖ |
| `gateway_requests_total` | counter | `rail`, `dialect`, `status` | every data-plane request, by the status the gateway returned |
| `gateway_upstream_seconds` | histogram | `rail` | upstream round-trip, first byte to last |
| `gateway_tokens_total` | counter | `rail`, `class` | usage recorded from upstream bodies in four classes: `in` (UNCACHED input — the openai dialect's `prompt_tokens` minus `cached_tokens`), `cache_read`, `cache_write`, `out` — the split the window draw and the cost ledger price from ⚖ |
| `gateway_subscription_utilization` | gauge | `rail`, `window` | last-seen `anthropic-ratelimit-unified-<window>-utilization` (0–1) on the subscription rail — capacity, not dollars ⚖ |
| `gateway_subscription_reset_seconds` | gauge | `rail`, `window` | last-seen `anthropic-ratelimit-unified-<window>-reset` (unix seconds) |
| `gateway_credential_resolve_total` | counter | `rail`, `outcome` | every ref resolution verdict |

| description | event (world `policy-default`, upstream-ok) || series | value |
|---|---||---|---|
| "a dispatch raises the active gauge" | worker dispatched on opencode || `gateway_sessions_active{rail="opencode"}` | 1 |
| "a release lowers it" | …then released || `gateway_sessions_active{rail="opencode"}` | 0 |
| "a dispatch is counted with its identity" | worker dispatched on opencode || `gateway_sessions_total{rail="opencode",role="worker",stack="platform",decision="dispatch"}` | 1 |
| "a defer is counted with no rail ⚖" | worker deferred (rail-capacity) || `gateway_sessions_total{rail="none",role="worker",stack="platform",decision="defer"}` | 1 |
| "a served request is counted by status" | one openai-dialect call on opencode || `gateway_requests_total{rail="opencode",dialect="openai",status="200"}` | 1 |
| "a refused request is counted by its status" | an expired token on `/anthropic/v1/messages` || `gateway_requests_total{rail="none",dialect="anthropic",status="401"}` | 1 |
| "an upstream 429 keeps its status" | upstream-429 on openrouter || `gateway_requests_total{rail="openrouter",dialect="openai",status="429"}` | 1 |
| "upstream time is observed per rail" | one call on anthropic || `gateway_upstream_seconds_count{rail="anthropic"}` | 1 |
| "tokens are counted by class" | upstream-ok-cached answers `usage {input_tokens: 12, cache_read_input_tokens: 300, cache_creation_input_tokens: 40, output_tokens: 7}` on anthropic || `gateway_tokens_total{rail="anthropic",class="in"}` / `"cache_read"` / `"cache_write"` / `"out"` | 12 / 300 / 40 / 7 |
| "the subscription windows are read" | one call on anthropic, answered with `anthropic-ratelimit-unified-{5h,7d}-{utilization,reset}` || `gateway_subscription_utilization{rail="anthropic",window="5h"}` / `"7d"`; `gateway_subscription_reset_seconds{…}` | 0.13 / 0.67; 1792172400 / 1792274400 |
| "a resolution verdict is counted" | the anthropic ref is a definitive miss || `gateway_credential_resolve_total{rail="anthropic",outcome="definitive"}` | 1 |

| description | the series || label | allowed values |
|---|---||---|---|
| "rail is the rail enum plus none" | any || `rail` | `anthropic`, `opencode`, `openrouter`, `none` |
| "role is the role enum" | sessions_total || `role` | `worker`, `reviewer`, `coordinator`, `responder`, `retro`, `prober`, `researcher` |
| "stack is a policy key" | sessions_total || `stack` | the keys of `policy.stacks` (`platform`, `oracle` in `policy-default`) |
| "decision is the answer enum" | sessions_total || `decision` | `dispatch`, `defer` |
| "dialect is the two paths" | requests_total || `dialect` | `anthropic`, `openai` |
| "status is a numeric HTTP status" | requests_total || `status` | the codes this gateway returns (`200`, `400`, `401`, `403`, `429`, `501`, `502`, `503`, `504`) and the upstream statuses relayed |
| "class is one of the four usage classes" | tokens_total || `class` | `in`, `cache_read`, `cache_write`, `out` |
| "window is 5h or 7d" | subscription_utilization || `window` | `5h`, `7d` |
| "outcome is the verdict class" | credential_resolve_total || `outcome` | `resolved`, `definitive`, `transient` |
| "no task label, ever" | any || — | no label named `task`, `session`, `id`, `model` |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: USD per request" | upstream-ok on openrouter || tokens only | the `/generation` harvest, the cost ledger |
| "⚑ gap: a slot freed is not announced" | a release on a full rail || the gauge drops; nothing is pushed | the capacity doorbell |
| "⚑ gap: the store mode is not a metric" | the DB fell open to memory || only `/healthz` says so | a `gateway_db_mode` family, and the alert on it |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-METRICS.md"

</details>
