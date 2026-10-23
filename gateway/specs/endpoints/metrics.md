---
id: EP-METRICS
use-cases: [UC-1]
schema: metrics.schema.json
---
# GET /metrics — the `gateway_*` families, with bounded labels only

The evidence surface the alert belts read. Thirty-two families, Prometheus text format, no auth
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
| [GW-SESSIONS-AUTH](sessions.md#gw-sessions-auth) (owned there) | `families.gateway_control_plane_unauthenticated_total` | — | linked — the rollout knob's soak signal; its increments are rows there |
| [GW-SESSIONS-ADMIT](sessions.md#gw-sessions-admit) §Capacity (owned there) | `families.gateway_cells_cooled`, `families.gateway_credentials_rejected` | — | linked — the admission's transport facts as gauges |
| [GW-RAIL-ANTHROPIC](anthropic-messages.md#gw-rail-anthropic) / [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter) (owned there) | `families.gateway_requests_incomplete_total` | — | linked — the stream-completeness rule |
| [GW-CATALOG-GO](catalog.md#gw-catalog-go) (owned there) | `families.gateway_go_catalog_*` | — | linked — the Go catalog's freshness, size and refresh outcomes; their values are rows there |
| [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter) (owned there) | `families.gateway_provider_requests_total`, `families.gateway_provider_failovers_total` | — | linked — the provider axis: attempts per cell and failovers; their values are rows there and below |
| [GW-CATALOG-OR](catalog.md#gw-catalog-or) (owned there) | `families.gateway_openrouter_catalog_*`, `families.gateway_openrouter_cells`, `families.gateway_canary_*` | — | linked — the OpenRouter catalog's freshness and refresh outcomes, the cells by entry state, the canary meter and verdicts; their values are rows there |
| [GW-CODEX-HEADROOM §Gauges](openai-responses.md#gauges) (owned there) | `families.gateway_subscription_utilization`, `families.gateway_subscription_reset_seconds` | — | linked — on the codex rail the two gauges come from an ACCEPTED headroom report, not from headers; their values are rows there |
| [GW-CODEX-HEADROOM §Poll](openai-responses.md#poll) (owned there) | `families.gateway_codex_usage_poll_total` | — | linked — the gateway's own usage poll by outcome, every outcome from 0; its values are rows there |
| [GW-CODEX-HEADROOM §Upstream headers](openai-responses.md#upstream-headers) (owned there) | `families.gateway_codex_upstream_headroom_total` | — | linked — the relayed answers' headroom-header reads by outcome, every outcome from 0; its values are rows there |

## GW-METRICS

| family | type | labels | what it counts |
|---|---|---|---|
| `gateway_sessions_active` | gauge | `rail` | sessions neither released nor expired, per rail — the admission counter |
| `gateway_sessions_total` | counter | `rail`, `role`, `stack`, `decision` | every `POST /sessions` answer; `rail` = `none` on a defer ⚖ |
| `gateway_requests_total` | counter | `rail`, `dialect`, `status` | every data-plane request, by the status the gateway returned |
| `gateway_upstream_seconds` | histogram | `rail` | upstream round-trip, first byte to last |
| `gateway_tokens_total` | counter | `rail`, `class` | usage recorded from upstream bodies in four classes: `in` (UNCACHED input — the openai dialect's `prompt_tokens` minus `cached_tokens`), `cache_read`, `cache_write`, `out` — the split the window draw and the cost ledger price from ⚖ |
| `gateway_subscription_utilization` | gauge | `rail`, `window` | last-seen `anthropic-ratelimit-unified-<window>-utilization` (0–1) on the subscription rail — capacity, not dollars ⚖; on the codex rail the last ACCEPTED headroom report's `used_percent` / 100 ([GW-CODEX-HEADROOM §Gauges](openai-responses.md#gauges)) |
| `gateway_subscription_reset_seconds` | gauge | `rail`, `window` | last-seen `anthropic-ratelimit-unified-<window>-reset` (unix seconds); on the codex rail the accepted report's `resets_at` |
| `gateway_credential_resolve_total` | counter | `rail`, `outcome` | every ref resolution verdict |
| `gateway_upstream_auth_rejected_total` | counter | `rail` | every upstream 401/403 the gateway reads as a CREDENTIAL verdict — the request answered 424 `upstream-auth` ([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary); a policy refusal, 403 `upstream-refused`, is not counted here): the event series the dead-key alert reads; `gateway_credentials_rejected` below is the state. Every rail renders from 0 ⚖ |
| `gateway_cells_cooled` | gauge | `rail` | (rail, model, provider) cells an upstream 429 cooled, until their reset — admission skips them ([§Capacity](sessions.md#capacity--the-ladders-capacity-half)); counted per rail (`model` is no label on this gauge); every rail renders from 0 |
| `gateway_credentials_rejected` | gauge | `rail` | rail credentials an upstream 401/403 rejected, until a 2xx on them or a new value — the alert hook for a dead key; every rail renders from 0 ⚖ |
| `gateway_strikes_total` | counter | `class`, `source` | strikes written to the store ([GW-SESSIONS-OUTCOME](sessions.md#gw-sessions-outcome)): `class` a strike class of the one vocabulary, `source` `outcome` (the consumer) or `gateway` (a transport fact) |
| `gateway_sessions_reaped_total` | counter | `rail` | sessions released because their pod was gone ([GW-SESSIONS-LIVENESS](sessions.md#gw-sessions-liveness)); every rail renders from 0 |
| `gateway_codex_usage_poll_total` | counter | `outcome` | the codex rail's usage polls by outcome ([GW-CODEX-HEADROOM §Poll](openai-responses.md#poll)): `accepted` = the headroom took the report; the rest name why it did not. The family exists only while the policy declares the codex rail, then every outcome renders from 0 ⚖ — the alerts read `increase()` (an undeclared rail has no series, so `CodexUsagePollSilent` cannot fire on it) |
| `gateway_codex_upstream_headroom_total` | counter | `outcome` | the codex rail's relayed answers read for their `x-codex-*` headroom headers ([GW-CODEX-HEADROOM §Upstream headers](openai-responses.md#upstream-headers)): `accepted` = the headroom took the report, `absent` = no window header on the answer, the rest name the refusal. Declared-gated and rendered from 0 exactly like the poll family ⚖ |
| `gateway_credential_probes_total` | counter | `rail`, `outcome` | re-verifications of a rejected credential ([§Capacity](sessions.md#capacity--the-ladders-capacity-half)): `cleared` (a 2xx), `rejected` (a credential verdict again), `inconclusive` (no verdict) |
| `gateway_requests_incomplete_total` | counter | `rail`, `dialect`, `reason` | 2xx answers whose body stopped before its end — `no-terminal`, `timeout`, `transport-error`, `client-closed` ([GW-RAIL-ANTHROPIC](anthropic-messages.md#gw-rail-anthropic)) |
| `gateway_go_catalog_age_seconds` | gauge | `source` | seconds since the source's last good snapshot was fetched — absent until one exists ([GW-CATALOG-GO](catalog.md#gw-catalog-go)) |
| `gateway_go_catalog_models` | gauge | `source` | models in the source's last good snapshot; 0 = none yet |
| `gateway_go_catalog_refresh_total` | counter | `source`, `outcome` | refresh attempts by outcome; every pair renders from 0 |
| `gateway_go_catalog_last_outcome` | gauge | `source`, `outcome` | 1 for the outcome of the source's latest attempt, 0 for the others — survives no restart, and needs none: the first refresh runs at start |
| `gateway_go_catalog_policy_models_missing` | gauge | `source` | policy Go models the source's snapshot does not cover — a count, so no `model` label |
| `gateway_control_plane_unauthenticated_total` | counter | `route`, `reason` | every control-plane call with no valid caller token — admitted under `control_plane_auth: observe`, refused under `enforce`; every (`route`, `reason`) pair renders from 0, so a flat series reads as "no such call" ⚖ |
| `gateway_provider_requests_total` | counter | `rail`, `model`, `provider`, `outcome` | every ATTEMPT on a (rail, model, provider) cell of the openrouter rail by how it ended ([GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter)): `ok`, `incomplete`, the pre-byte failures the gateway fails over on (`5xx`, `429`, `unreachable`, `timeout`, `content-type`, `provider-error`) and the request-scoped answers it never does (`refused`, `auth`, `edge`). ⚖ `model` is bounded to the POLICY's openrouter ids, `provider` to the endpoint SNAPSHOT's slugs plus `unattributed` — never a value a response invented (one slugged by rule renders `other`) |
| `gateway_provider_failovers_total` | counter | `model`, `from`, `to` | requests reissued to the next provider before the first byte; the same bounds |
| `gateway_openrouter_catalog_age_seconds` | gauge | — | seconds since the last good OpenRouter catalog refresh ([GW-CATALOG-OR](catalog.md#gw-catalog-or)) — absent until one exists; `OpenRouterCatalogStale` reads it |
| `gateway_openrouter_catalog_models` | gauge | — | models in the last good snapshot; 0 = none yet |
| `gateway_openrouter_catalog_refresh_total` | counter | `outcome` | refresh attempts by outcome; every outcome renders from 0 |
| `gateway_openrouter_catalog_last_outcome` | gauge | `outcome` | 1 for the latest attempt's outcome, 0 for the others — `OpenRouterCatalogParseFailed` reads it |
| `gateway_openrouter_cells` | gauge | `state` | (model, provider) cells of the catalog by entry state — `candidate`, `eligible`, `excluded`; a provider's service tiers are one cell |
| `gateway_canary_spend_usd` | gauge | — | metered canary spend over the trailing day at the cell's endpoint price |
| `gateway_canary_budget_exhausted` | gauge | — | 1 while the canary cap (per refresh or per day) is spent and candidate cells wait — `GatewayCanaryBudgetExhausted` reads it |
| `gateway_canary_rides_total` | counter | `outcome` | canary verdicts: `eligible` (a clean ride), `excluded` (a struck one) — and `no-verdict` (a 429'd one: the cell backs off, nothing is judged) |
| `gateway_canary_admissions_total` | counter | `outcome` | canary admissions by answer: `dispatch`, `budget`, `not-due`, `not-in-catalog` |
| `gateway_rail_choice_total` | counter | `model`, `rail`, `reason` | admissions where the tier named one model on two allowed rails ([GW-MODEL-TIERS §The rail choice](catalog.md#the-rail-choice)), by the rail that walked first and why — `price`, `clean-rate`, `headroom`, `not-in-catalog`, `no-eligible-endpoint`; ⚖ `model` is the twin's openrouter spelling, the provider families' bound |
| `gateway_tier_evidence_age_seconds` | gauge | — | seconds since the mounted tier-evidence snapshot's `snapshot_at` (`GATEWAY_BENCHMARKS`) — absent when none is mounted; `TierEvidenceStale` reads it |

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
| "an upstream auth rejection is counted apart" | upstream-401 on opencode || `gateway_upstream_auth_rejected_total{rail="opencode"}` / `gateway_requests_total{rail="opencode",dialect="openai",status="424"}` | 1 / 1 |
| "an unreachable upstream is not an auth rejection" | upstream-down on opencode || `gateway_upstream_auth_rejected_total{rail="opencode"}` / `gateway_requests_total{rail="opencode",dialect="openai",status="502"}` | 0 / 1 |
| "every rail's rejection count renders from 0 ⚖" | no request yet || `gateway_upstream_auth_rejected_total{rail=…}` for `anthropic`, `openrouter`, `opencode`, `codex` | 0 each |
| "a resolution verdict is counted" | the anthropic ref is a definitive miss || `gateway_credential_resolve_total{rail="anthropic",outcome="definitive"}` | 1 |
| "a cooled cell is counted on its rail" | upstream-429 on openrouter || `gateway_cells_cooled{rail="openrouter"}` | 1 |
| "a rejected credential is counted on its rail" | upstream-401 on openrouter || `gateway_credentials_rejected{rail="openrouter"}` | 1 |
| "an incomplete stream is counted by reason" | upstream-stream-truncated on opencode (`stream: true`) || `gateway_requests_incomplete_total{rail="opencode",dialect="openai",reason="no-terminal"}` | 1 |
| "a strike is counted by class and source" | a worker session reports `no-verdict` || `gateway_strikes_total{class="no-verdict",source="outcome"}` | 1 |
| "a reaped session is counted on its rail" | a bound opencode session whose pod is gone, one reaper pass || `gateway_sessions_reaped_total{rail="opencode"}` | 1 |
| "a credential re-probe is counted by outcome" | opencode 401 (`upstream-401-key-expired`), +60 s, the re-probe answered upstream-ok || `gateway_credential_probes_total{rail="opencode",outcome="cleared"}` | 1 |
| "the transport-fact gauges render every rail from 0" | no request yet || `gateway_cells_cooled{rail=…}` / `gateway_credentials_rejected{rail=…}` for `anthropic`, `openrouter`, `opencode`, `codex` | 0 each |

The provider families (world `policy-default · openrouter-endpoints` — the snapshot of
`deepseek/deepseek-v4.1-flash`, the openrouter heavy tier; [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter)):

| description | event || series | value |
|---|---||---|---|
| "an attempt is counted on its cell by how it ended" | a ride whose deepinfra attempt answered 500, served by atlas-cloud || `gateway_provider_requests_total{rail="openrouter",model="deepseek/deepseek-v4.1-flash",provider="deepinfra",outcome="5xx"}` / `{…,provider="atlas-cloud",outcome="ok"}` | 1 / 1 |
| "a failover is counted from and to" | the same || `gateway_provider_failovers_total{model="deepseek/deepseek-v4.1-flash",from="deepinfra",to="atlas-cloud"}` | 1 |
| "an unpinned attempt that names no provider is unattributed ⚖" | a ride on `deepseek/deepseek-v4-flash` (no snapshot entry), the answer unnamed || `gateway_provider_requests_total{rail="openrouter",model="deepseek/deepseek-v4-flash",provider="unattributed",outcome="ok"}` | 1 |
| "a provider the snapshot lacks renders as other ⚖" | the same, the answer names Sail Research || `gateway_provider_requests_total{…,model="deepseek/deepseek-v4-flash",provider="other",outcome="ok"}` | 1 |

| description | the series || label | allowed values |
|---|---||---|---|
| "rail is the rail enum plus none" | any || `rail` | `anthropic`, `opencode`, `openrouter`, `codex`, `none` — `codex` renders `gateway_sessions_active{rail="codex"} 0` even where no policy declares it (the rail ships dark) ⚖ |
| "role is the role enum" | sessions_total || `role` | `worker`, `reviewer`, `coordinator`, `responder`, `retro`, `prober`, `researcher` |
| "stack is a policy key" | sessions_total || `stack` | the keys of `policy.stacks` (`platform`, `oracle` in `policy-default`) |
| "decision is the answer enum" | sessions_total || `decision` | `dispatch`, `defer` |
| "dialect is the three paths" | requests_total || `dialect` | `anthropic`, `openai`, `responses` ([GW-RAIL-CODEX](openai-responses.md#gw-rail-codex)) |
| "status is a numeric HTTP status" | requests_total || `status` | the codes this gateway returns (`200`, `400`, `401`, `403`, `424`, `429`, `501`, `502`, `503`, `504`) and the upstream statuses relayed |
| "class is one of the four usage classes" | tokens_total || `class` | `in`, `cache_read`, `cache_write`, `out` |
| "window is 5h or 7d" | subscription_utilization || `window` | `5h`, `7d`, `other` — on the codex rail the headroom profile's minutes spelled in this vocabulary (300 → `5h`, 10080 → `7d`; a profile minute outside it renders `other` ⚖, [GW-CODEX-HEADROOM §Gauges](openai-responses.md#gauges)) |
| "outcome is the verdict class" | credential_resolve_total || `outcome` | `resolved`, `definitive`, `transient` |
| "route is the control-plane route" | control_plane_unauthenticated_total || `route` | `admit` (`POST /sessions`), `lookup` (`GET /sessions/{id}`), `release` (`DELETE`), `outcome` (`POST /sessions/{id}/outcome`), `list` (`GET /sessions?task=`) |
| "reason is why no caller identity was read" | control_plane_unauthenticated_total || `reason` | `absent` (no bearer), `invalid` (the review is not authenticated for audience `agent-gateway`), `review-transient` (the TokenReview API did not answer) |
| "class is a strike class, source the writer" | strikes_total || `class` / `source` | the strike classes of the vocabulary / `outcome`, `gateway` |
| "reason is why a 2xx body stopped before its end" | requests_incomplete_total || `reason` | `no-terminal`, `timeout`, `transport-error`, `client-closed` |
| "source is the catalog source" | go_catalog_refresh_total || `source` | `config` (the console's V2 config), `docs` (the vendor's Go page) |
| "state is a cell's entry state ⚖" | openrouter_cells || `state` | `candidate`, `eligible`, `excluded` |
| "a canary outcome is a verdict, an admission an answer" | canary_rides_total / canary_admissions_total || `outcome` | `eligible`, `excluded`, `no-verdict` / `dispatch`, `budget`, `not-due`, `not-in-catalog` |
| "the catalog outcome is the refresh outcome" | go_catalog_refresh_total || `outcome` | `ok`, `fetch-failed`, `parse-failed`, `implausible` |
| "model is a policy openrouter id ⚖" | provider_requests_total, provider_failovers_total, rail_choice_total || `model` | the openrouter rail's policy models (wire ids); else `other` |
| "reason is why the rail choice fell ⚖" | rail_choice_total || `reason` | `price`, `clean-rate`, `headroom`, `not-in-catalog`, `no-eligible-endpoint` |
| "provider is a snapshot slug or unattributed ⚖" | provider_requests_total (`from`, `to` on provider_failovers_total) || `provider` | the endpoint snapshot's tag-base slugs, `unattributed`; else `other` |
| "no task label, ever" | any || — | no label named `task`, `session`, `id`, `token`; `model` only on the two provider families and the rail choice, bounded to the policy's set ⚖ |

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: USD per request" | upstream-ok on openrouter || tokens only | the `/generation` harvest, the cost ledger |
| "⚑ gap: a slot freed is not announced" | a release on a full rail || the gauge drops; nothing is pushed | the capacity doorbell |
| "⚑ gap: the store mode is not a metric" | the DB fell open to memory || only `/healthz` says so | a `gateway_db_mode` family, and the alert on it |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-METRICS.md"

</details>
