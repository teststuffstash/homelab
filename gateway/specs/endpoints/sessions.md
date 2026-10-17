---
id: EP-SESSIONS
use-cases: [UC-1]
schema: sessions.schema.json
---
# POST /sessions · GET /sessions/{id} · DELETE /sessions/{id} · POST /sessions/{id}/env — the launcher's one question

*May this unit run now, with which harness, and what goes in the pod's env.* The control-plane
seam of the island ([UC-1](../use-cases/uc-1-worker-ride.md) steps ① and ④). The caller sends
`(stack, role, task, round)` and optional `tier` / `harness` / `rail`; the gateway answers
`dispatch` (a session, a rail, a harness, a model, the pod's complete LLM env) or `defer` (a
typed reason and when to ask again). The caller authenticates with its projected ServiceAccount
token and may ask only for what the policy's `callers` grant it ([GW-SESSIONS-AUTH](#gw-sessions-auth)).
A body carrying `bind` gets a dispatch without the
credential, and the bound pod pulls its env itself ([GW-SESSIONS-PULL](#gw-sessions-pull)). No caller names a model: the policy does, and every
data-plane request is resolved from the session identity
([GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve)).

## Interface — the machine half

**[`sessions.schema.json`](sessions.schema.json)** is the single source for the request,
response and error shapes; the service **imports it**. Coupling is enforced by
`scripts/spec_gate.py` in `devbox run ci` (rule 7).

| Requirement | Governs (schema) | Error codes | Status |
|---|---|---|---|
| [GW-SESSIONS-ADMIT](#gw-sessions-admit) | `post.input`, `post.output` (`dispatch` / `defer`) | `malformed-body`, `harness-rail-mismatch`, `credential-transient` | v0 + the ladder's capacity half ([§Capacity](#capacity--the-ladders-capacity-half): window utilization, the 429 latch, the Go window draw); the ladder's class/tier/cell walk, strikes, cooldowns and the capacity doorbell are `⚑ gap` (rows below); `/route` compatibility is `⚑ gap` (not served; consumers move to this endpoint) |
| [GW-SESSIONS-ENV](#gw-sessions-env) | `post.output.dispatch.env`, `post.output.dispatch.context_tokens` | — | v0 for `claude` / `opencode` / `goose` / `codex` (the codex rail ships dark — [openai-responses.md](openai-responses.md)); `⚑ gap (2026-10-16, PR #2646 → work #2650)`: the codex env's native-CLI turn evidence is local-only (the "⚖ local evidence" row); `⚑ gap (2026-10-17, PR #2656 → work #2650)`: the goose/opencode wire evidence is a one-off in-cluster probe, not CI (the "⚖ cluster evidence" row; the shadow cells are the end-to-end check), and opencode's provider-package fetch under enforced egress is unobserved (the "⚑ gap: opencode's provider package" row) |
| [GW-SESSIONS-TOKEN](#gw-sessions-token) | `post.output.dispatch.session`, `get.output` | `session-not-found` | v0 |
| [GW-SESSIONS-RELEASE](#gw-sessions-release) | `delete.output`, `get.output.released_at` | `session-not-found` | v0 |
| [GW-SESSIONS-PULL](#gw-sessions-pull) | `post.input.bind`, `post.output.dispatch_bound`, `pull.output` | `pull-identity-refused`, `tokenreview-transient`, `env-already-delivered`, `session-released`, `session-expired`, `session-not-found` | v0; a codex `auth.command` re-read is `⚑ gap` (row below) |
| [GW-SESSIONS-AUTH](#gw-sessions-auth) | `caller`, `get.output.caller` | `caller-unauthenticated`, `caller-unknown`, `caller-stack-denied`, `caller-role-denied`, `caller-bind-denied`, `caller-not-owner`, `tokenreview-transient`, `session-not-found` | v0, deployed in `observe` (the knob); `⚑ gap (2026-10-17, PR #2683 → work #2684)`: a bind's ServiceAccount is not constrained per caller (the "⚑ gap: a bind's ServiceAccount" row); `⚑ gap (2026-10-17, PR #2683 → work #2685)`: `agent-coordinator` is one SA for many workflows (the "⚑ gap: one ServiceAccount" row) |
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
**first rail** whose `active_sessions < rails.<rail>.max_sessions`, that is not
capacity-blocked ([§Capacity](#capacity--the-ladders-capacity-half)), AND whose credential for
the stack resolves ([GW-CRED-RESOLVE](#gw-cred-resolve)). None → `defer`, whose `reason` and
`retry_after_s` are those of the blocked rail that frees **first** (a full rail frees after the
policy's `defer_retry_s`, 60 s; ties go to walk order — ⚖ a gateway choice, the old proxy has no multi-rail answer); a walk blocked only on credentials
defers `credential-unresolved`. The walk is filtered
by the harness first: `claude` speaks the anthropic dialect (rails `anthropic`, `opencode`);
`opencode` / `goose` speak openai (rails `openrouter`, `opencode`); `codex` speaks responses
(rail `codex` only — gated by account headroom, [GW-CODEX-HEADROOM](openai-responses.md#gw-codex-headroom),
whose admission rows live there); a rail the harness
cannot speak is skipped, and an **explicit** `harness` × `rail` pair that cannot speak is a 400
`harness-rail-mismatch`, never a silent skip. `defer` is HTTP 200 — a normal answer the caller
polls after `retry_after_s`; only a malformed body or a transient credential fault is an HTTP
error. ⚖ The gateway admits on count, capacity and credential: no strikes, no cooldowns, no
provider pins — the rest of the ADR-096 ladder is a gap, rendered as rows, not omitted. The
caller never polls `/anthropic-limit` / `/opencode-limit`: the defer IS the limit answer.

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
| "codex where no allowed rail serves responses" | `harness: codex` (worker, `policy-default` — no codex rail) || 200 | — (`decision: defer`, `role-rail-denied`) |
| "codex against a rail that does not serve responses" | `harness: codex`, `rail: openrouter` || 400 | harness-rail-mismatch |

### Counting

| description | before || active after | `gateway_sessions_active{rail}` |
|---|---||---|---|
| "a dispatch counts on its rail" | opencode 0 → worker dispatched || opencode 1 | opencode = 1 |
| "a release frees the slot" | opencode 1 → `DELETE` it || opencode 0 | opencode = 0 |
| "an expiry frees the slot without a DELETE" | opencode 1, `expires_at` passed || opencode 0 | opencode = 0 |
| "a defer counts nothing" | opencode 3 → worker deferred || opencode 3 | opencode = 3 |

### Capacity — the ladder's capacity half

Three per-rail checks after the slot count ([model-routing.md §The ladder](../../../docs/agents/model-routing.md#the-ladder--rail--class--tier--cell)'s
capacity facts, moved from the old proxy's two limit endpoints into the admission answer). Every
threshold, hold and price is policy data under `rails.<rail>.admission` — none is a code literal —
and each is ⚖ **copied** from the old proxy, which keeps serving its own copy until it retires
([§Who owns which fact](../../../docs/agents/model-routing.md#who-owns-which-fact): this is a
duplicate by design for that window, not a second owner). A rail with no `admission` key has no
capacity check. A blocked rail is skipped like a full one; it frees when the **last** of its
blocks lifts.

- **Window utilization** (`anthropic`): the last-seen `anthropic-ratelimit-unified-<w>-utilization`
  of each window at/over `utilization_thresholds.<w>` blocks the rail until that window's
  `-reset`. ⚖ 5h **0.80** = `ANTHROPIC_UTIL_THRESHOLD`'s code default (`openrouter-proxy.py`; unset in
  its `deployment.yaml`), 7d **0.95** = `ANTHROPIC_UTIL_THRESHOLD_7D` (`deployment.yaml`). A reading
  whose reset has passed is no reading (the old proxy's "dead data" rule); a reading older than
  `reading_stale_s` (**900 s**) is no reading either — an unavailable reading admits, never blocks.
  ⚖ The 900 s bound has **no** old-proxy precedent (it sees every subscription ride; this gateway
  sees only its own, so its reading ages out) — a guess the operator may tune.
- **429 latch** (`anthropic`, `opencode`): an upstream 429 on a rail whose policy sets
  `latch_429_hold_s` blocks the rail until `retry-after` (a non-numeric or absent one → the hold);
  any 2xx on the rail clears it early. ⚖ holds **900 s** = `ANTHROPIC_429_HOLD_S` /
  `GO_CAPACITY_HOLD_S` (`openrouter-proxy.py`). `openrouter` declares none: the old proxy never
  latches it on one 429 (its account latch needs cross-model 429s — a gap row below).
- **Go window draw** (`opencode`): each `window_draw.windows.<w>` sums the rail's metered (2xx)
  requests inside the window open at `now`, priced from the four token classes at **list** rates —
  uncached input and output at `in`/`out`, each cache class at its own rate (a `null` rate draws
  nothing), the peak row inside a peak hour by the REQUEST's timestamp, an unpriced model at
  `fallback` — gometer's `window_draw()` semantics. A window at/over `threshold × budget_usd`
  blocks the rail until it resets. ⚖ Every number is copied from `argocd/resources/openrouter-proxy/gometer.py`
  (snapshot 2026-09-17) — a **duplicate until the old proxy retires**: `GO_PRICES` /
  `GO_PRICES_PEAK` rows for the policy's priced Go model, `fallback` = `_GO_MAX_PRICE`/2 per side,
  `GO_PEAK_HOURS_UTC` / `GO_PEAK_WEEKDAYS`, `_GO_WINDOW_DEFAULTS` (5h $12 `chain` · 7d $30
  `weekly` Mon 00:00 · 30d $60 `monthly` 13th 11:30) and `OPENCODE_UTIL_THRESHOLD`'s 0.80. The
  `chain` window opens at the first request after the previous one expired (`router.go_usage_chain_open`).
  Prices apply at READ time from the ledger (`requests` × `sessions.model`), so a policy price edit
  re-prices the open windows.

Rows run at T0 = Fri 2027-01-15 08:00:00Z (the test clock; a Go peak hour). Every reading and
every usage arrives through the data plane (a session + one `POST /anthropic/v1/messages` the fake
upstream answers as stated) — never seeded.

| description | reading (5h / 7d; resets T0 + 3600 / T0 + 259200) | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| "the 5h window at its threshold defers the subscription until its reset" | 0.80 / 0.10 | — | reviewer, `rail: anthropic` || defer | — | rail-window | 3600 |
| "the 5h window under its threshold admits" | 0.79 / 0.10 | — | reviewer, `rail: anthropic` || dispatch | anthropic | — | — |
| "the 7d window under its own threshold admits" | 0.10 / 0.94 | — | reviewer, `rail: anthropic` || dispatch | anthropic | — | — |
| "the 7d window at its threshold defers until the 7d reset" | 0.10 / 0.95 | — | reviewer, `rail: anthropic` || defer | — | rail-window | 259200 |
| "both windows over: the later reset names the wait" | 0.90 / 0.97 | — | reviewer, `rail: anthropic` || defer | — | rail-window | 259200 |
| "a window whose reset has passed is no reading" | 0.90 (reset T0 − 1) / 0.10 | — | reviewer, `rail: anthropic` || dispatch | anthropic | — | — |
| "a reading older than reading_stale_s is no reading ⚖" | 0.90 / 0.10 | +901 s | reviewer, `rail: anthropic` || dispatch | anthropic | — | — |
| "a reading just inside reading_stale_s still defers" | 0.90 / 0.10 | +900 s | reviewer, `rail: anthropic` || defer | — | rail-window | 2700 |
| "the walk continues past a blocked subscription" | 0.90 / 0.10 | — | reviewer (policy walk) || dispatch | opencode | — | — |

| description | arrange (the fake's `upstream-429` sends `retry-after: 30`) | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| "an anthropic 429 latches the subscription for its retry-after" | reviewer ride on anthropic → 429 | — | reviewer, `rail: anthropic` || defer | — | rail-latched | 30 |
| "a 429 without retry-after latches for the policy hold" | reviewer ride on anthropic → 429, no `retry-after` | — | reviewer, `rail: anthropic` || defer | — | rail-latched | 900 |
| "the latch lifts at its expiry" | reviewer ride on anthropic → 429 | +30 s | reviewer, `rail: anthropic` || dispatch | anthropic | — | — |
| "any 2xx on the rail clears the latch" | reviewer ride on anthropic → 429, the same session → 200 | — | reviewer, `rail: anthropic` || dispatch | anthropic | — | — |
| "a Go 429 latches the Go rail" | worker ride on opencode → 429 | — | worker, `rail: opencode` || defer | — | rail-latched | 30 |
| "a latched rail is skipped, the walk continues" | worker ride on opencode → 429 | — | worker (policy walk) || dispatch | openrouter | — | — |
| "a rail whose policy declares no latch does not latch ⚖" | worker ride on openrouter → 429 | — | worker, `rail: openrouter` || dispatch | openrouter | — | — |
| "every rail blocked: the rail that frees first names the defer ⚖" | worker ride on opencode → 429; openrouter at its 20 | — | worker (policy walk) || defer | — | rail-latched | 30 |

The Go rows: a worker ride on opencode rides `opencode-go/deepseek-v4-flash` (peak in 0.30 / out
1.20 / cache_read 0.006 / cache_write `null`; off-peak 0.15 / 0.60 / 0.003 / `null`), a reviewer
ride the unpriced `opencode-go/claude-sonnet-4-6` (fallback 9.00 / 9.00); thresholds $9.60 (5h) /
$24 (7d) / $48 (30d). The expected value of each row is computed in its test's comment.

| description | ride usage (at) | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| "a 5h draw over threshold defers the Go rail until the window resets" | worker in 20M, out 3.2M (T0) — $9.84 | — | worker, `rail: opencode` || defer | — | rail-window | 18000 |
| "a 5h draw under threshold admits" | worker in 20M, out 2.8M (T0) — $9.36 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "an off-peak request draws at the base rate" | worker in 20M, out 3.2M (T0 + 2 h) — $4.92 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "cache reads draw at their own rate, not the input rate" | worker cache_read 1000M (T0) — $6.00, not $300 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "a cache class with no rate draws nothing ⚖" | worker cache_write 1000M (T0) — $0 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "an unpriced model draws at the fallback row" | reviewer in 1M, out 0.1M (T0) — $9.90 | — | worker, `rail: opencode` || defer | — | rail-window | 18000 |
| "the walk continues past a full Go window" | worker in 20M, out 3.2M (T0) | — | worker (policy walk) || dispatch | openrouter | — | — |
| "an expired 5h window draws nothing" | worker in 20M, out 3.2M (T0) | +18000 s | worker, `rail: opencode` || dispatch | opencode | — | — |
| "the 7d window binds once the 5h one has expired" | worker in 90M (T0) — $27 | +18000 s | worker, `rail: opencode` || defer | — | rail-window | 212400 |
| "the 30d window binds once the week has reset" | worker in 170M (T0) — $51 | +230401 s | worker, `rail: opencode` || defer | — | rail-window | 2287799 |

### Named gaps (rows that exist so the omission is visible)

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: FU-109 tier thresholds" | a dispatch-unit tier asking past the 5h threshold || deferred at the per-window threshold | the old proxy RAISES a window's threshold per consumer tier (`model-classes.json` `tier_thresholds`); the gateway's `light`/`standard`/`heavy` is not that vocabulary |
| "⚑ gap: a latch survives a restart" | a 429 latch, then a gateway roll || the latch is forgotten; the next 429 re-latches | the old proxy persists its latches (`router.latch_save`); this one is in memory |
| "⚑ gap: the OpenRouter account latch" | 402s / cross-model 429s / credit below the floor on a stack key || no latch | the old proxy's `rpd` / `credit` / hard-402 legs (homelab#158) and the key headroom poll ([GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter)) |
| "⚑ gap: a Go 402" | an upstream 402 on opencode || no latch | the old proxy latches a Go 402 for `GO_CAPACITY_402_HOLD_S` (1800 s) |
| "⚑ gap: the Go draw is the gateway's own traffic only" | Go spend through the old proxy or the jail shim || not in this ledger — this draw is a lower bound of the account's | the account-wide reading (the old proxy's ledger, the jail shim's reports) |
| "⚑ gap: long-context price tiers" | a Go model with a `GO_PRICES_LONG` row || — no policy model has one | gometer's long-context override; add the row with the first such model |
| "⚑ gap: a model struck on this task last round" | worker, round 2 after a strike || the policy model, unchanged | ADR-096 strikes / cooldowns / pair holds |
| "⚑ gap: labels, urgency, budget class" | body carries none, none read || — | the ADR-096 ladder's inputs; `tier` is the only size knob |
| "⚑ gap: `POST /route`" | any || 404 | not served by this gateway — consumers move to `/sessions`; the old proxy keeps serving it |
| "⚑ gap: a capacity doorbell" | a rail frees a slot || nothing is pushed | the caller polls `retry_after_s` |

<details markdown="1"><summary>Evidence</summary>

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
anyway). The openai-dialect rows carry what the **pinned** CLI was observed to read — not the
brief's names. They were probed in-cluster on 2026-10-17 in an `agent-base:2026.10.15-gd10904baa8fa`
pod (goose 1.49.0, opencode 1.18.35), with a loopback listener standing in for this gateway and
recording each request's path, `Authorization` and body `model`. A harness that ignores a var the
gateway hands it is a failed row, not a passed one:

- **goose** reads `OPENAI_BASE_URL` / `OPENAI_API_KEY` / `GOOSE_MODEL` only when
  `GOOSE_PROVIDER=openai`. Without it the run exits `No provider configured` before any request.
  With it: `GET <base>/models`, then `POST <base>/chat/completions` with `Bearer <key>` and
  `model` = `GOOSE_MODEL` (title side-calls included).
- **opencode** does not read `OPENCODE_MODEL`. Given only `OPENAI_BASE_URL` / `OPENAI_API_KEY`,
  its built-in openai provider sent `POST <base>/responses` with its OWN default models
  (`gpt-5.6-terra`, `gpt-5.4-nano`), so that env is unusable here. One `OPENCODE_CONFIG_CONTENT`
  value holding an `@ai-sdk/openai-compatible` provider (`baseURL`, `apiKey`, the model as both
  `model` and `small_model`) gave `POST <base>/chat/completions` with `Bearer <key>` and
  `model: deepseek-v4-flash` on every request. So opencode's env is that ONE var.

The model var carries the policy id with its rail prefix removed (`claude/sonnet` →
`sonnet`, `opencode-go/deepseek-v4-flash` → `deepseek-v4-flash`; openrouter ids are bare) — the
same strip `agents/agent-session.sh` performs today. `context_tokens` is the policy's per-model
window or `null` — a null is "not declared", never a guess.

**`codex`** (world `policy-codex` — the rail ships dark): the pinned CLI reads its provider from
config, not from env — observed with codex-cli 0.161.0 (`experiments/codex-rail/compat.py`):
a bare `OPENAI_BASE_URL` + `OPENAI_API_KEY` with no provider block is ignored (the CLI dialled
`api.openai.com`, refused by the fixture's closed proxy), while a `[model_providers.<id>]` block
with `base_url`, `wire_api = "responses"`, `env_key` and the model completes a turn. So the env
carries the three VALUES that block needs and the harness wrapper renders the block from them
(`base_url = $OPENAI_BASE_URL`, `env_key = "OPENAI_API_KEY"`, `model = $CODEX_MODEL`) ⚖ — the
only var the CLI itself reads is the `env_key` one, the token. The compat harness renders exactly
that block from a real dispatch answer; its run is the local-evidence row below.

| description | harness | rail | model (policy) || env var | value |
|---|---|---||---|---|
| "claude: the base url is this gateway's anthropic path" | claude | anthropic | claude/sonnet || `ANTHROPIC_BASE_URL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/anthropic` |
| "claude: the auth token is the session token" | claude | anthropic | claude/sonnet || `ANTHROPIC_AUTH_TOKEN` | the session token |
| "claude: the model name is the alias the CLI resolves" | claude | anthropic | claude/sonnet || `ANTHROPIC_MODEL` | `sonnet` |
| "claude on the [Go rail](../../../docs/agents/chainless-redesign.md): same three vars, Go's model name" | claude | opencode | opencode-go/claude-sonnet-4-6 || `ANTHROPIC_MODEL` | `claude-sonnet-4-6` |
| "opencode: an openai-compatible provider block" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENCODE_CONFIG_CONTENT` → `.provider.gateway.npm` | `@ai-sdk/openai-compatible` |
| "opencode: the provider's base url is this gateway's openai path" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENCODE_CONFIG_CONTENT` → `.provider.gateway.options.baseURL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/openai/v1` |
| "opencode: the provider's api key is the session token" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENCODE_CONFIG_CONTENT` → `.provider.gateway.options.apiKey` | the session token |
| "opencode: the session model is the bare id under that provider" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENCODE_CONFIG_CONTENT` → `.model` | `gateway/deepseek-v4-flash` |
| "opencode: the title model is the same id" | opencode | opencode | opencode-go/deepseek-v4-flash || `OPENCODE_CONFIG_CONTENT` → `.small_model` | `gateway/deepseek-v4-flash` |
| "goose: the provider is goose's openai provider" | goose | openrouter | deepseek/deepseek-v4-flash || `GOOSE_PROVIDER` | `openai` |
| "goose: the base url is this gateway's openai path" | goose | openrouter | deepseek/deepseek-v4-flash || `OPENAI_BASE_URL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/openai/v1` |
| "goose: the api key is the session token" | goose | openrouter | deepseek/deepseek-v4-flash || `OPENAI_API_KEY` | the session token |
| "goose: the model var carries the bare id" | goose | openrouter | deepseek/deepseek-v4-flash || `GOOSE_MODEL` | `deepseek/deepseek-v4-flash` |
| "codex: the base url is this gateway's openai path (wrapper-rendered) ⚖" | codex | codex | codex/fixture-model || `OPENAI_BASE_URL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/openai/v1` |
| "codex: the api key is the session token, read through env_key ⚖" | codex | codex | codex/fixture-model || `OPENAI_API_KEY` | the session token |
| "codex: the model var carries the bare id (wrapper-rendered) ⚖" | codex | codex | codex/fixture-model || `CODEX_MODEL` | `fixture-model` |

| description | harness || vars present | vars absent |
|---|---||---|---|
| "claude's env is exactly three vars" | claude || `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL` | `ANTHROPIC_API_KEY`, any `OPENAI_*`, any `OPENROUTER_*` |
| "opencode's env is exactly the provider config" | opencode || `OPENCODE_CONFIG_CONTENT` | any `ANTHROPIC_*`, any `OPENAI_*`, any `OPENROUTER_*` |
| "goose's env is exactly four vars" | goose || `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `GOOSE_PROVIDER`, `GOOSE_MODEL` | any `ANTHROPIC_*`, any `OPENROUTER_*` |
| "no env value is a real key" | any || every value (each leaf of opencode's config) is the token, a URL, a model name or a provider/package name | any value matching the [GW-REDACT](#gw-redact) patterns |
| "codex's env is exactly three vars ⚖" | codex || `OPENAI_BASE_URL`, `OPENAI_API_KEY`, `CODEX_MODEL` | any `ANTHROPIC_*`, any `OPENROUTER_*` |
| "⚖ cluster evidence: the pinned goose and opencode send this gateway's dialect from this env" | goose 1.49.0, opencode 1.18.35 (agent-base 2026.10.15-gd10904baa8fa) || goose: `GET /openai/v1/models` + `POST /openai/v1/chat/completions`, `Bearer` = the token, `model` = `GOOSE_MODEL`; opencode: `POST /openai/v1/chat/completions` only, `Bearer` = the token, `model` = the bare id | the in-cluster probe of 2026-10-17 (the PR that resolved these rows), not CI; the shadow cells (specs-reviewer.md §Shadow runs) are the end-to-end check |
| "⚑ gap (2026-10-17, PR #2656 → work #2650): opencode's provider package under enforced egress" | opencode || the probe namespace (`agent-coordinator`) reached `registry.npmjs.org` and `models.dev` (HTTP 200), so whether opencode FETCHES `@ai-sdk/openai-compatible` at run time was not observed | a ride whose egress blocks npm (homelab#990's class) is unproven: it may wedge before the first request |
| "⚖ local evidence: the pinned Codex CLI completes a turn from this env through the gateway" | codex (codex-cli 0.161.0) || the provider block rendered from the dispatch `env`; `OPENAI_API_KEY` in the child env | no `auth.json`, no operator config (a fresh `CODEX_HOME`) — `experiments/codex-rail/evidence.json`, not CI |

| description | model (policy) || `context_tokens` |
|---|---||---|
| "a declared `context_tokens` is echoed" | opencode-go/deepseek-v4-flash || 1000000 |
| "an undeclared `context_tokens` is null, never a default" | claude/sonnet || null |

<details markdown="1"><summary>Evidence</summary>

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
| "GET returns the row without the token" | dispatch → `GET /sessions/{id}` || 200; `id, stack, role, task, round, rail, harness, model, created_at, expires_at, released_at, requests, tokens_in, tokens_out, tokens_cache_read, tokens_cache_write, caller` (the admitting caller, [GW-SESSIONS-AUTH](#gw-sessions-auth); `null` here — the row's caller sent no token under `observe`); no `token`, no `token_hash` |
| "GET on an unknown id" | `GET /sessions/nope` || 404 `session-not-found` |
| "expiry is the policy TTL" | dispatch at T || `expires_at` = T + 14400 s (`policy-default`) |
| "a request through the data plane is counted on the row" | dispatch → one `upstream-ok` call → GET || `requests` = 1, `tokens_in`/`tokens_out` = the upstream `usage` (`tokens_in` = uncached input; the cache classes in `tokens_cache_read`/`tokens_cache_write` — GW-METRICS) |

<details markdown="1"><summary>Evidence</summary>

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

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-RELEASE.md"

</details>

## GW-SESSIONS-PULL

*The pod pulls its own env; the launcher never holds the session token* (operator ruling
2026-10-17, FU-270). A `POST /sessions` body may carry **`bind: {namespace, serviceaccount, pod?}`**
— the identity of the pod the launcher is about to create. A bound `dispatch` carries **no
credential**: `session.id`, `session.expires_at`, `rail`, `harness`, `model`, `context_tokens`,
plus `env_keys` (the NAMES of the env [GW-SESSIONS-ENV](#gw-sessions-env) would have handed over,
in its order) and `pull_url` (`<this gateway>/sessions/{id}/env`) — no `session.token`, no `env`.
⚖ `context_tokens` and `session.expires_at` stay in the bound answer: neither is a credential, and
the launcher reads both (the harness's context window, the TTL it reports); the env's model
*values* do not — the launcher has `model`, the pod gets the wire names in its pulled env.
The token does not exist yet: the row holds an unminted placeholder no token hashes to. **Without
`bind` the answer is byte-for-byte GW-SESSIONS-ENV's** — the specs reviewer's launcher depends on it.
Which namespaces a caller may bind is the policy's `callers` entry for it ([GW-SESSIONS-AUTH](#gw-sessions-auth)):
the bind is no longer the caller's word alone.

The pod then calls **`POST /sessions/{id}/env`** with `Authorization: Bearer <its projected
ServiceAccount token>`, audience **`agent-gateway`**. The gateway TokenReviews it
(`spec.audiences: [agent-gateway]`) and serves only when the review is `authenticated`, lists
that audience, names the user `system:serviceaccount:<bind.namespace>:<bind.serviceaccount>`,
and — when the bind names a pod — carries the extra `authentication.kubernetes.io/pod-name`
equal to exactly that pod. Then it **mints the token** (GW-SESSIONS-TOKEN's shape; only the
sha256 is stored) and answers `{id, expires_at, env}`, the `env` exactly GW-SESSIONS-ENV's.
The checks run in a fixed order — the id (404 `session-not-found`), the identity (403
`pull-identity-refused`; a review the API cannot answer is 503 `tokenreview-transient`,
retriable — also when the API refuses the GATEWAY's review with 401/403 ⚖: that is the gateway's own
RBAC, not a verdict on the caller), the session's state (401 `session-released` / `session-expired`, exactly as the
data plane refuses it), delivery (409 `env-already-delivered`) — so a caller with the wrong
identity learns nothing about a session but that its id exists. **At most once** ⚖: the
launcher's pods are `restartPolicy: Never` (`agents/agent-session.sh`), so a legitimate pod
pulls exactly once, and a leaked projected token cannot fetch the credential a second time
inside its own lifetime. The identity check is the git broker's pattern
(`GIT_CRED_BROKER_URL`, FU-089 — the old proxy's `_token_review`: the caller's projected token,
TokenReview'd, a failed review never a pass-through); the gateway's RBAC adds
`tokenreviews.create` and nothing else.

Why a pull and not a launcher-written Secret (#2667's first cut): the loop SA cannot create
Secrets in fixer namespaces, deliberately. **Credential writes stay gateway-only** — the codex
rail's OAuth refresh needs ONE owner per account writing each rotation durably
([codex spike §Gateway prototype](../../../docs/spikes/codex-subscription-rail.md#gateway-prototype--isolated-build-2026-10-16-fu-270)'s
OAuth row and refresh-persistence paragraph); a launcher that wrote the session's Secret would
be a second writer of credential material. And Codex's own seam is a pull: a custom provider's
`auth.command` prints the bearer from a command
([§Public ChatGPT/Codex OAuth contract](../../../docs/spikes/codex-subscription-rail.md#public-chatgptcodex-oauth-contract)),
so a codex harness will later point that command at this endpoint — not built (the gap row below).

### The bound dispatch answer

| description | body || result |
|---|---||---|
| "a bound dispatch carries the session's identity, not its credential ⚖" | worker, `bind: {platform-agents, agentstack-worker, fixer-1}` || keys exactly `decision`, `session` (`id`, `expires_at`), `rail`, `harness`, `model`, `env_keys`, `pull_url`, `context_tokens`; no `gws_` anywhere in the body |
| "env_keys names the opencode env" | worker (opencode) + bind || `env_keys` = `[OPENCODE_CONFIG_CONTENT]` |
| "env_keys names the claude env" | reviewer (claude) + bind || `env_keys` = `[ANTHROPIC_BASE_URL, ANTHROPIC_AUTH_TOKEN, ANTHROPIC_MODEL]` |
| "env_keys names the goose env" | worker, `harness: goose`, `rail: openrouter` + bind || `env_keys` = `[OPENAI_BASE_URL, OPENAI_API_KEY, GOOSE_PROVIDER, GOOSE_MODEL]` |
| "pull_url is this gateway's pull path for the session" | worker + bind || `pull_url` = `http://agent-gateway.agent-egress.svc.cluster.local:8080/sessions/«id»/env` |
| "without bind the dispatch answer is unchanged" | worker, no `bind` || `session.token` + `env` (GW-SESSIONS-ENV); no `env_keys`, no `pull_url` |
| "a bound session holds no token until its pull" | worker + bind, read the DB || `token_hash` = `unminted:«id»` (no sha256 hex equals it) |
| "a bind without a serviceaccount is malformed" | `bind: {namespace: platform-agents}` || 400 `malformed-body` |
| "a bind namespace that is not a DNS label is malformed" | `bind: {namespace: Platform_Agents, serviceaccount: agentstack-worker}` || 400 `malformed-body` |

### Who may pull

The fake TokenReview answers the presented token as the `presented` cell says: **the bound
identity** = authenticated · audiences `[agent-gateway]` · `system:serviceaccount:platform-agents:agentstack-worker`
· pod-name `fixer-1`; every other cell changes ONE thing from it — `unauthenticated` (`authenticated: false`),
`the kube API audience` (audiences `[https://kubernetes.default.svc]`), another username, `pod-name fixer-2`,
`no pod-name extra`; `no bearer` sends no `Authorization` header. `session`: **bound to fixer-1** =
`bind: {platform-agents, agentstack-worker, fixer-1}`; **bound, no pod** = the same without `pod`;
**unbound** = dispatched without `bind`.

| description | session | presented || status | code |
|---|---|---||---|---|
| "the bound pod's projected token is served" | bound to fixer-1 | the bound identity || 200 | — |
| "no bearer token" | bound to fixer-1 | no bearer || 403 | pull-identity-refused |
| "a token the API does not authenticate" | bound to fixer-1 | unauthenticated || 403 | pull-identity-refused |
| "the bound identity without the gateway audience" | bound to fixer-1 | the kube API audience || 403 | pull-identity-refused |
| "another ServiceAccount of the bound namespace" | bound to fixer-1 | system:serviceaccount:platform-agents:default || 403 | pull-identity-refused |
| "the bound ServiceAccount name in another namespace" | bound to fixer-1 | system:serviceaccount:oracle-agents:agentstack-worker || 403 | pull-identity-refused |
| "another pod of the bound ServiceAccount" | bound to fixer-1 | pod-name fixer-2 || 403 | pull-identity-refused |
| "a token with no pod binding when the bind names a pod" | bound to fixer-1 | no pod-name extra || 403 | pull-identity-refused |
| "a bind without a pod admits any pod of its ServiceAccount ⚖" | bound, no pod | pod-name fixer-2 || 200 | — |
| "an unbound session refuses every pull ⚖" | unbound | the bound identity || 403 | pull-identity-refused |
| "an unknown id" | — (`POST /sessions/nope/env`; no review is made) | the bound identity || 404 | session-not-found |
| "the TokenReview API fails" | bound to fixer-1 | (the review raises: 5xx / unreachable) || 503 | tokenreview-transient |
| "the TokenReview API refuses the gateway itself ⚖" | bound to fixer-1 | (the API answers the gateway's review 403 — its own RBAC) || 503 | tokenreview-transient |

### What a pull returns

| description | sequence || result |
|---|---||---|
| "the pull answers the opencode env GW-SESSIONS-ENV would have" | worker (opencode) bound → pull || `env` keys = `env_keys`; the provider `apiKey` is a fresh `^gws_[A-Za-z0-9_-]{32}$`; `baseURL` `…/openai/v1`, model `gateway/deepseek-v4-flash` |
| "the pull answers the claude env" | reviewer (claude) bound → pull || `ANTHROPIC_AUTH_TOKEN` a fresh `gws_` token, `ANTHROPIC_BASE_URL` `…/anthropic`, `ANTHROPIC_MODEL` `sonnet` |
| "the pull answers the goose env" | worker goose/openrouter bound → pull || `OPENAI_API_KEY` a fresh `gws_` token, `OPENAI_BASE_URL` `…/openai/v1`, `GOOSE_PROVIDER` `openai`, `GOOSE_MODEL` `deepseek/deepseek-v4-flash` |
| "the pulled token rides the data plane" | pull → `POST /openai/v1/chat/completions` with it (`upstream-ok`) || 200; the row's `requests` = 1 |
| "the row stores the pulled token's sha256 only" | pull, read the DB || `token_hash` = sha256(token); the token appears nowhere in the sqlite dump |

### Only once, and in order

| description | sequence || result |
|---|---||---|
| "a second pull by the same pod is refused ⚖" | pull, pull again (same identity) || 409 `env-already-delivered`; the first token is still served |
| "a second pull by another pod is refused by identity first ⚖" | pull, then pod-name `fixer-2` || 403 `pull-identity-refused` |
| "a released session is refused as the data plane refuses it" | `DELETE`, then pull || 401 `session-released` |
| "an expired session is refused as the data plane refuses it" | the clock past `expires_at`, then pull || 401 `session-expired` |
| "a wrong identity on a released session is refused by identity first ⚖" | `DELETE`, then a pull whose token reviews as pod-name `fixer-2` || 403 `pull-identity-refused` (not 401) |

The log rows (a pull line names the session and the identity, never either token; a refused
pull never logs the presented token; a JWT is masked by shape) are
[GW-REDACT](#gw-redact)'s.

### Named gaps

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: a codex `auth.command` re-runs" | a codex harness whose provider `auth.command` calls the pull URL || its second run is 409 `env-already-delivered` | Codex re-runs the command every `refresh_interval_ms` (default 5 min); a token-only, same-pod re-read is needed before a codex harness can use this endpoint — not built |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-PULL.md"

</details>

## GW-SESSIONS-AUTH

*The control plane knows who is asking* (operator order 2026-10-17, FU-270). Every `POST /sessions`,
`GET /sessions/{id}` and `DELETE /sessions/{id}` carries **`Authorization: Bearer <the caller's
projected ServiceAccount token>`**, audience **`agent-gateway`**. The gateway reviews it through the
**same** TokenReview path as [the env pull](#gw-sessions-pull) (`TokenReviewer`, `spec.audiences:
[agent-gateway]`, one implementation) and reads the reviewed username,
`system:serviceaccount:<ns>:<sa>`, as the caller. The policy's **`callers`** map, keyed by that
username, says what the caller may ask for: its admissions' `stacks` and `roles`, and the
`bind_namespaces` a [`bind`](../glossary.md#bind) may name. Exact values only, every key required, a
key that is not a ServiceAccount username refuses the policy load. So a wildcard can never be
written. The caller is stored on the session row (`caller`, returned by `GET`), and `GET` / `DELETE`
belong to that caller. The env pull is NOT caller-checked here: its caller is the bound pod, which
GW-SESSIONS-PULL checks against the bind.

⚖ The checks run in a fixed order (an alternative would read the body first, or answer 404 before the caller check): the caller's token (401 / 503), its `callers` entry (403
`caller-unknown`), the body (400, as [GW-SESSIONS-ADMIT](#gw-sessions-admit)), then the body against
the entry: stack, role, bind namespace (403, one code each). For `GET` / `DELETE` the order is the
token, the entry, the id (404), the owner (403 `caller-not-owner`). A caller without a valid token
therefore learns nothing about a body or an id.

**`control_plane_auth`** is the rollout knob. ⚖ It and `callers` are REQUIRED in the policy: a policy silent about its callers must not default to "anyone" (or to `observe`). **`enforce`**: a call with no
bearer, or one the review does not authenticate for audience `agent-gateway`, is 401
`caller-unauthenticated`; a review the API cannot answer is 503 `tokenreview-transient`, as on the
pull. **`observe`**: that same call is **admitted**. The gateway writes one log line naming the
route and the reason, and counts it on
**`gateway_control_plane_unauthenticated_total{route,reason}`** ([GW-METRICS](metrics.md#gw-metrics)).
It counts in both modes. The deployed policy starts in `observe`; it flips to `enforce` once every
caller sends its token and the series stays flat. ⚖ **A VALID token is checked against `callers`
in both modes.** Under `observe`, a caller the gateway can identify but that is unlisted, or that
asks outside its entry, is refused exactly as under `enforce`. The knob forgives a missing identity
during the rollout. It never waves through a known identity the policy does not grant.

Rows run against two worlds. **`policy-default`** is `observe`, so every other row on this page
runs unchanged without a caller token. **`policy-enforce`** is the same document with `enforce`
([worlds/README.md](../worlds/README.md)). Both hold two fixture callers.
**The platform loop** = `system:serviceaccount:platform-agents:agentstack-loop` · stacks
`[platform]` · roles `[worker]` · bind namespaces `[platform-agents]`. **The specs reviewer** =
`system:serviceaccount:agent-coordinator:agent-coordinator` · stacks `[platform]` · roles
`[reviewer, worker]` · bind namespaces `[]`. The fake TokenReview answers a presented token as the
`presented` cell says. A caller's name = authenticated · audiences `[agent-gateway]` · that
username. **An unlisted ServiceAccount** = the same, as `system:serviceaccount:platform-agents:default`.
**Unauthenticated** = `authenticated: false`. **The kube API audience** = the platform loop with
audiences `[https://kubernetes.default.svc]`. **No bearer** sends no `Authorization` header.
**(The review raises)** = the API is away. The body is a platform worker bound to
`{platform-agents, agentstack-worker, fixer-1}` unless the row says otherwise.

### Who may call

| description | world | presented || status | result |
|---|---|---||---|---|
| "the platform loop admits a bound platform worker" | policy-enforce | the platform loop || 200 | `dispatch`; the row's `caller` = `system:serviceaccount:platform-agents:agentstack-loop` |
| "no bearer, under enforce" | policy-enforce | no bearer || 401 | caller-unauthenticated; `{route="admit",reason="absent"}` + 1 |
| "a token the API does not authenticate, under enforce" | policy-enforce | unauthenticated || 401 | caller-unauthenticated; `{route="admit",reason="invalid"}` + 1 |
| "a token for another audience, under enforce" | policy-enforce | the kube API audience || 401 | caller-unauthenticated; `{route="admit",reason="invalid"}` + 1 |
| "the TokenReview API fails, under enforce" | policy-enforce | (the review raises) || 503 | tokenreview-transient, `retry-after: 5`; `{route="admit",reason="review-transient"}` + 1 |
| "the caller check precedes the body ⚖" | policy-enforce | no bearer; the body is not JSON || 401 | caller-unauthenticated, not 400 |
| "no bearer, under observe, is admitted and counted ⚖" | policy-default | no bearer || 200 | `dispatch`; the row's `caller` = null; `{route="admit",reason="absent"}` + 1 |
| "an invalid token, under observe, is admitted and counted" | policy-default | unauthenticated || 200 | `dispatch`; `{route="admit",reason="invalid"}` + 1 |
| "a review the API cannot answer, under observe, is admitted and counted ⚖" | policy-default | (the review raises) || 200 | `dispatch`; `{route="admit",reason="review-transient"}` + 1 |
| "an unlisted ServiceAccount, under enforce" | policy-enforce | an unlisted ServiceAccount || 403 | caller-unknown |
| "an unlisted ServiceAccount is refused under observe too ⚖" | policy-default | an unlisted ServiceAccount || 403 | caller-unknown; the unauthenticated series unchanged (the caller WAS identified) |

### What a caller may ask for

World `policy-default` (the same answers under `policy-enforce`: a known caller is checked identically).

| description | presented | body || status | result |
|---|---|---||---|---|
| "a stack outside the caller's entry" | the platform loop | stack `oracle`, worker, bind `{platform-agents, agentstack-worker}` || 403 | caller-stack-denied |
| "a role outside the caller's entry" | the platform loop | platform `reviewer` + bind || 403 | caller-role-denied |
| "a bind namespace outside the caller's entry" | the platform loop | platform worker, bind `{oracle-agents, agentstack-worker}` || 403 | caller-bind-denied |
| "a caller with no bind namespaces may not bind" | the specs reviewer | platform reviewer + bind `{platform-agents, agentstack-worker}` || 403 | caller-bind-denied |
| "an unbound admission needs no bind namespace" | the specs reviewer | platform reviewer, no bind || 200 | `dispatch` with `session.token` + `env` ([GW-SESSIONS-ENV](#gw-sessions-env)) |
| "a known caller's malformed body is still 400" | the platform loop | no `task` || 400 | malformed-body |

### Lookup and release belong to the admitting caller

| description | world | sequence || status | result |
|---|---|---||---|---|
| "the admitting caller reads its session" | policy-enforce | the platform loop admits, then GETs || 200 | the row, `caller` = the platform loop |
| "the admitting caller releases its session" | policy-enforce | the platform loop admits, then DELETEs || 200 | `released_at` set |
| "another listed caller may not read it" | policy-enforce | the platform loop admits; the specs reviewer GETs || 403 | caller-not-owner |
| "another listed caller may not release it" | policy-enforce | the platform loop admits; the specs reviewer DELETEs || 403 | caller-not-owner; the session stays active (`gateway_sessions_active` unchanged) |
| "a release without a bearer, under enforce" | policy-enforce | the platform loop admits; DELETE with no bearer || 401 | caller-unauthenticated; `{route="release",reason="absent"}` + 1 |
| "a lookup without a bearer, under observe, is served and counted" | policy-default | the platform loop admits; GET with no bearer || 200 | the row; `{route="lookup",reason="absent"}` + 1 |
| "a session admitted with no caller is released by any listed caller ⚖" | policy-default | admitted with no bearer; the specs reviewer DELETEs || 200 | `released_at` set: a row with no recorded caller has no owner to protect, and refusing would pin its rail slot until the TTL |
| "an unknown id is 404 only after the caller check ⚖" | policy-enforce | the platform loop GETs `/sessions/nope` || 404 | session-not-found |
| "an unknown id without a bearer, under enforce ⚖" | policy-enforce | GET `/sessions/nope`, no bearer || 401 | caller-unauthenticated |

### One TokenReview path, and the pull stays the pod's

| description | world | sequence || result |
|---|---|---||---|
| "the caller's token is reviewed by the pull's reviewer, for audience agent-gateway" | policy-enforce | the gateway's reviewer is the kube one on a fake API that answers the platform loop's username; `POST /sessions` with a bearer || 200 `dispatch`; the API received exactly one TokenReview, `spec.audiences: [agent-gateway]`, sent with the gateway's own ServiceAccount token |
| "the env pull is not caller-checked" | policy-enforce | the platform loop admits a bound worker; the bound pod (not in `callers`) pulls || 200 `{id, expires_at, env}`, as GW-SESSIONS-PULL |

### The policy shape

| description | the policy's control-plane keys || load |
|---|---||---|
| "a caller key that is not a ServiceAccount username refuses the load" | `callers: {"system:serviceaccount:platform-agents:*": …}` || PolicyError |
| "a caller naming a stack the policy does not hold refuses the load" | the platform loop's `stacks: [nope]` || PolicyError |
| "a caller entry missing a key refuses the load" | the platform loop without `bind_namespaces` || PolicyError |
| "a policy without control_plane_auth refuses the load ⚖" | `control_plane_auth` absent || PolicyError |
| "a policy without callers refuses the load ⚖" | `callers` absent || PolicyError |
| "the deployed callers are today's two dispatchers" | `argocd/resources/agent-gateway/policy.json` || loads; `callers` = exactly `system:serviceaccount:platform-agents:agentstack-loop` (stacks `[platform]`, roles `[worker]`, bind namespaces `[agent-runtime, homelab, openrouter-operator]`) and `system:serviceaccount:agent-coordinator:agent-coordinator` (`[platform]`, `[reviewer, worker]`, `[]`) |

The deployed entries are today's in-cluster callers, named by the SA they run as. The platform
stack's graduated coordinator pod (`agents/coordinator-session.sh --loop-ns`, SA `agentstack-loop`)
is the one in-cluster caller of `agents/agent-session.sh`. It binds into the platform repo
namespaces that hold an `agentstack-worker` SA. ⚖ `agent-coordinator` is a platform repo but holds
no `agentstack-worker`, so a bind there could never be pulled and is not granted. The specs-review
tick and its shadow cells run as `agent-coordinator` (`agents/coordinator/specs-review-argo.yaml`):
role `reviewer`, plus ⚖ `worker` for the goose@openrouter shadow cell, which rode `--role worker`
because the reviewer role has no openrouter rail
([specs-reviewer.md §Shadow runs](../../../docs/agents/specs-reviewer.md#shadow-runs--harness--rail-cells-gatewayplanmd-step-3)). A jail
canary mints the loop SA's token (`kubectl create token`) and acts as that dispatcher.

### What the log says

| description | sequence || the log holds | the log does not hold |
|---|---||---|---|
| "a dispatch line names the caller, never its token" | the platform loop admits || `caller=system:serviceaccount:platform-agents:agentstack-loop` | the presented token |
| "an unauthenticated call is one line naming the route and the reason" | `policy-default`, no bearer || exactly one `control-plane: admit unauthenticated (absent) — ADMITTED under control_plane_auth=observe` | — |

### Named gaps

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: a bind's ServiceAccount is not constrained per caller" | the platform loop binds `{homelab, default}` || admitted, because the namespace is listed | an entry lists bind NAMESPACES only, so any pod SA in a listed namespace can be named; a per-caller ServiceAccount list is the next key if a listed namespace ever holds an SA that must not ride |
| "⚑ gap: one ServiceAccount, many workflows" | any workflow in `agent-coordinator` presents its pod's token || authorized as the specs reviewer | `callers` is per ServiceAccount, and `agent-coordinator` runs every workflow in that namespace (reflexes, deploy-revert, the review tick, …); a dedicated SA for the specs-review templates narrows the grant to that tick |

<details><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-AUTH.md"

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

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-CRED-RESOLVE.md"

</details>

## GW-REDACT

No log line the gateway emits contains a credential value: a bearer value, a `gws_` token, an
`sk-ant-oat…` OAuth token, an `sk-or-v1-…` OpenRouter key, a JWT (the projected ServiceAccount
token a pod presents to [the env pull](#gw-sessions-pull)), or the Go key's value. The log
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
| "a projected ServiceAccount token (a JWT)" | `"review eyJhbGciOiJSUzI1NiJ9.eyJGQUtFIjoxfQ.RkFLRS1TSUc"` || `review <redacted>` | `eyJ` |

| description | path || the log holds | the log does not hold |
|---|---||---|---|
| "an upstream 401 body is summarised, not copied" | `upstream-401` on openrouter || `upstream-auth openrouter 401` | the upstream body, the key |
| "a bad inbound header is logged by shape" | `Authorization: Bearer notatoken` || `session-unknown` | `notatoken` |
| "a dispatch line names the session id, never the token" | dispatch || the session id | the token |
| "a pull line names the session and the identity, never either token" | a bound dispatch → its pull ([GW-SESSIONS-PULL](#gw-sessions-pull)) || `env pulled id=«id» by system:serviceaccount:platform-agents:agentstack-worker` | the presented ServiceAccount token, the minted `gws_` token |
| "a refused pull never logs the presented token" | a pull whose token reviews as another ServiceAccount || `pull-identity-refused` | the presented token |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-REDACT.md"

</details>
