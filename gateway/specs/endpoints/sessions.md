---
id: EP-SESSIONS
use-cases: [UC-1]
schema: sessions.schema.json
---
# POST /sessions · GET /sessions/{id} · DELETE /sessions/{id} · POST /sessions/{id}/env · POST /sessions/{id}/outcome — the launcher's one question

*May this unit run now, with which harness, and what goes in the pod's env.* The control-plane
seam of the island ([UC-1](../use-cases/uc-1-worker-ride.md) steps ① and ④). The caller sends
`(stack, role, task, round)` and optional `tier` / `harness` / `rail` — or, for the catalog's
entry canary, `canary: {model, provider}` ([GW-CATALOG-OR](catalog.md#gw-catalog-or)); the gateway answers
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
| [GW-SESSIONS-ADMIT](#gw-sessions-admit) | `post.input` (incl. `canary` — [GW-CATALOG-OR](catalog.md#gw-catalog-or)'s entry canary, whose rows live there: the defers `canary-not-due`, `canary-budget`, `not-in-catalog`), `post.output` (`dispatch` / `defer`; `dispatch.rail_choice` — [GW-MODEL-TIERS](catalog.md#gw-model-tiers)'s rail choice, whose rows live there) | `malformed-body`, `harness-rail-mismatch`, `credential-transient` | v0 + the ladder's capacity half ([§Capacity](#capacity--the-ladders-capacity-half): window utilization, the 429 latch, the Go window draw, the per-cell 429 cooldown, the rejected credential) + the openrouter provider axis ([§The provider axis](#the-provider-axis-openrouter) — the cell is (rail, model, provider), `no-eligible-provider`; homelab#2741); the ladder's class/tier walk, strikes and the capacity doorbell are `⚑ gap` (rows below); `/route` compatibility is `⚑ gap` (not served; consumers move to this endpoint) |
| [GW-SESSIONS-ENV](#gw-sessions-env) | `post.output.dispatch.env`, `post.output.dispatch.context_tokens` | — | v0 for `claude` / `opencode` / `goose` / `codex` (the codex rail ships dark — [openai-responses.md](openai-responses.md)); `⚑ gap (2026-10-16, PR #2646 → work #2650)`: the codex env's native-CLI turn evidence is local-only (the "⚖ local evidence" row); `⚑ gap (2026-10-17, PR #2656 → work #2650)`: the goose/opencode wire evidence is a one-off in-cluster probe, not CI (the "⚖ cluster evidence" row; the shadow cells are the end-to-end check), and opencode's provider-package fetch under enforced egress is unobserved (the "⚑ gap: opencode's provider package" row) |
| [GW-SESSIONS-TOKEN](#gw-sessions-token) | `post.output.dispatch.session`, `get.output` | `session-not-found` | v0 |
| [GW-SESSIONS-RELEASE](#gw-sessions-release) | `delete.output`, `get.output.released_at` | `session-not-found` | v0 |
| [GW-SESSIONS-PULL](#gw-sessions-pull) | `post.input.bind`, `post.output.dispatch_bound`, `pull.output` | `pull-identity-refused`, `tokenreview-transient`, `env-already-delivered`, `session-released`, `session-expired`, `session-not-found` | v0; Codex same-pod token re-read after first delivery (below) |
| [GW-SESSIONS-LIVENESS](#gw-sessions-liveness) | `get.output.state`, `get.output.release_reason` | — | v0 |
| [GW-SESSIONS-AUTH](#gw-sessions-auth) | `caller`, `get.output.caller` | `caller-unauthenticated`, `caller-unknown`, `caller-stack-denied`, `caller-role-denied`, `caller-bind-denied`, `caller-not-owner`, `tokenreview-transient`, `session-not-found` | v0, deployed in `enforce` (the knob; `observe` 2026-10-17 until every caller sent its token); `⚑ gap (2026-10-17, PR #2683 → work #2684)`: a bind's ServiceAccount is not constrained per caller (the "⚑ gap: a bind's ServiceAccount" row); `⚑ gap (2026-10-17, PR #2683 → work #2685)`: `agent-coordinator` is one SA for many workflows (the "⚑ gap: one ServiceAccount" row) |
| [GW-SESSIONS-OUTCOME](#gw-sessions-outcome) | `outcome.input`, `outcome.output`, `outcome.strike`, `get.output.outcome` | `outcome-class-unknown`, `outcome-evidence-refused`, `outcome-judge-only`, `outcome-window-closed`, `outcome-conflict`, `caller-not-owner`, `session-not-found` | v0 — the admission's walk reads it ([§The retry contract](#the-retry-contract--model-lists-strikes-attempt)); `⚑ gap` rows below |
| [GW-CRED-RESOLVE](#gw-cred-resolve) | `post.output.defer.reason` (`credential-unresolved`) | `credential-transient` | v0 |
| [GW-REDACT](#gw-redact) | `$defs.error_envelope.error.message` (the one wire surface a log-shaped string reaches) + log lines (a formatter invariant) | — | v0 |
| [GW-MODEL-RESOLVE](anthropic-messages.md#gw-model-resolve) (owned there) | `post.output.dispatch.model` | — | linked — the model a dispatch names is the one every data-plane request must carry |
| [GW-ACCESS](../access.md#gw-access) (owned there) | `post.input.role` | — | linked — the role's rail set is the inventory's enforced column |

Rows below run against the **`policy-default` world**
([worlds/policy-default.json](../worlds/policy-default.json)) with `FakeSecrets` holding every
ref the policy names unless a row says otherwise; the canonical end-to-end pair lives in
[`uc-1/request.json`](../use-cases/uc-1/request.json) → [`uc-1/expected-response.json`](../use-cases/uc-1/expected-response.json).

## GW-SESSIONS-ADMIT

A `POST /sessions` body is admitted by walking `roles.<role>.rails` in order — ⚖ the role's
order yields once: when the tier's lists name ONE model on two allowed rails (a
[twin](../glossary.md#twin)), the rail whose twin cell costs less per clean ride walks first,
with that twin at its list's head, and the answer's `rail_choice` says why
([GW-MODEL-TIERS §The rail choice](catalog.md#the-rail-choice) owns those rows; `null` when no
twin) — and, inside each rail, the tier's ORDERED model list
([§The retry contract](#the-retry-contract--model-lists-strikes-attempt)) —
and picking the **first rail** whose `active_sessions < rails.<rail>.max_sessions`, that is not
capacity-blocked — the rail, or the [cell](../glossary.md#cell) its tier's model makes on it
([§Capacity](#capacity--the-ladders-capacity-half)) — AND whose credential for the stack resolves
([GW-CRED-RESOLVE](#gw-cred-resolve)) and has not been rejected upstream. None → `defer`, whose `reason` and
`retry_after_s` are those of the blocked rail that frees **first** (a full rail frees after the
policy's `defer_retry_s`, 60 s; ties go to walk order — ⚖ a gateway choice, the old proxy has no multi-rail answer); a walk blocked only on credentials
defers `credential-unresolved`, or `credential-rejected` when any of its credentials was rejected
upstream (⚖ the rejection outranks: it names the operator act, a rotation). The walk is filtered
by the harness first: `claude` speaks the anthropic dialect (rails `anthropic`, `opencode`);
`opencode` / `goose` speak openai (rails `openrouter`, `opencode`); `codex` speaks responses
(rail `codex` only — gated by account headroom, [GW-CODEX-HEADROOM](openai-responses.md#gw-codex-headroom),
whose admission rows live there); a rail the harness
cannot speak is skipped, and an **explicit** `harness` × `rail` pair that cannot speak is a 400
`harness-rail-mismatch`, never a silent skip. `defer` is HTTP 200 — a normal answer the caller
polls after `retry_after_s`; only a malformed body or a transient credential fault is an HTTP
error. ⚖ The gateway admits on count, capacity and credential: no strikes, no cooldowns, no
provider pins — the rest of the ADR-096 ladder is a gap, rendered as rows, not omitted. The
transport facts the gateway sees FIRST-HAND (a 429, a 401/403, a stream's end) are its own and are
rows below; a ride's outcome is the consumer's and is not read here. The
caller never polls `/anthropic-limit` / `/opencode-limit`: the defer IS the limit answer.

### Which rail, or why not

| description | role | harness | tier | active on rails (anthropic / opencode / openrouter) | credential state || decision | rail | model | reason |
|---|---|---|---|---|---||---|---|---|---|
| "a worker takes the first rail in its list" | worker | (policy: opencode) | (policy: standard) | 0 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/deepseek-v4.1-flash | — |
| "the first rail is full, the second is taken" | worker | (policy) | (policy) | 0 / 3 / 0 | all resolve || dispatch | openrouter | deepseek/deepseek-v4-flash | — |
| "every allowed rail is full" | worker | (policy) | (policy) | 0 / 3 / 20 | all resolve || defer | — | — | rail-capacity |
| "a reviewer rides the subscription first" | reviewer | (policy: claude) | (policy: heavy) | 0 / 0 / 0 | all resolve || dispatch | anthropic | claude/sonnet | — |
| "the subscription is full, the reviewer takes Go" | reviewer | (policy) | (policy) | 5 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/claude-haiku-5-5 | — |
| "the stack's anthropic ref does not resolve, the walk continues ⚖" | reviewer | (policy) | (policy) | 0 / 0 / 0 | anthropic_ref definitive miss || dispatch | opencode | opencode-go/claude-haiku-5-5 | — |
| "the only allowed rail's credential does not resolve" | prober | (policy) | (policy) | 0 / 0 / 0 | anthropic_ref definitive miss || defer | — | — | credential-unresolved |
| "an explicit tier picks the model inside the rail" | worker | (policy) | heavy | 0 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/claude-haiku-5-5 | — |
| "an explicit harness narrows the walk to its dialect" | worker | goose | (policy) | 0 / 0 / 0 | all resolve || dispatch | opencode | opencode-go/deepseek-v4.1-flash | — |
| "a harness that cannot speak the role's only rail ⚖" | prober | opencode | (policy) | 0 / 0 / 0 | all resolve || defer | — | — | role-rail-denied |
| "an explicit rail the role is not allowed" | worker | (policy) | (policy) | 0 / 0 / 0 | all resolve, `rail: anthropic` || defer | — | — | role-rail-denied |
| "an explicit rail the role is allowed is taken even when later in the list (logged as an override) ⚖" | worker | (policy) | (policy) | 0 / 0 / 0 | all resolve, `rail: openrouter` || dispatch | openrouter | deepseek/deepseek-v4-flash | — |
| "an unknown stack" | worker (stack `nope`) | (policy) | (policy) | 0 / 0 / 0 | — || defer | — | — | stack-unknown |

### The retry contract — model lists, strikes, `attempt`

*A failed attempt costs a re-dispatch, never a round* ([model-routing.md §The design's three
rules](../../../docs/agents/model-routing.md#the-designs-three-rules), rule 3). A rail tier names
an **ordered list** of models, `rails.<rail>.models.<tier>: [id, …]`; a bare string is the
one-item list (every policy written before this keeps loading). The walk reads the task's
**counted strikes** ([GW-SESSIONS-OUTCOME](#gw-sessions-outcome)) and takes, rail by rail, the
first model of the tier's list that the task has not struck: a cell-scoped strike excludes that
(rail, model), a model-scoped one excludes the model id on every rail, and a cooled cell
([§Capacity](#capacity--the-ladders-capacity-half)) is skipped as well. A rail with no admissible
model is passed over, and the walk moves on to the role's next rail. ⚖ When every candidate cell is
**struck**, and no rail is held only by time (capacity, latch, window, cooldown — those defer as
before, because waiting helps there), the answer is `defer` **`cells-exhausted` with no
`retry_after_s`**. Waiting does not help: the caller escalates (the old ladder's "chain exhausted
with the strike list"). ⚖ Model identity is the policy id: the same model on another rail is
another id, so a model strike on `claude/sonnet` does not exclude `opencode-go/claude-haiku-5-5`
(a gap row below).

`POST /sessions` carries **`attempt`** (default 1): the consumer's automatic re-admission counter at
this round. Strikes are keyed by TASK, not by attempt, so the exclusion holds however the attempt is
counted. `attempt` is what makes a re-run **detectable**. ⚖ The same caller re-admitting the same
(stack, task, round, attempt) for the same bound pod (both unbound counts as the same pod) while the
earlier session is still **active** is a re-run of that admission: a killed pod's re-run, or a slot
leaked by a SIGKILL (the 2026-10-17 experiment's probe left one active until its TTL). The earlier
session is **superseded**: it is released, and its token is refused from then on. Then this
admission proceeds. Never two live sessions for one attempt. Refusing would wedge the re-run until
the TTL; answering the old session again cannot work, because an unbound session's token exists only
as a hash. **What the gateway cannot detect:** a re-run that restarts at attempt 1 after the earlier
session was released or expired. The experiment saw Argo re-run a review as a fresh round-0
admission. It is admitted as new, but it meets the task's strikes all the same (the last row below).
The consumers' side: report the outcome before the DELETE, and on a strike re-admit at the SAME
round with `attempt + 1`, at most 2 automatic attempts (`agents/agent-session.sh` and
`agents/specs-reviewer-session.sh`, under `AGENT_GATEWAY=sessions` / the specs review).

World `policy-default`: `rails.anthropic.models.heavy` = `[claude/sonnet, claude/opus]` (the
reviewer's tier), `rails.openrouter.models.light` = `[deepseek/deepseek-v4-flash,
deepseek/deepseek-v4.1-flash]`, every other tier a bare string. The strikes are arranged through
the outcome endpoint on an earlier session of the SAME task. T = `specs-review homelab#2700`, round 0.

| description | arrange (the task's strikes) | body || decision | rail | model | reason |
|---|---|---||---|---|---|---|
| "a tier names an ordered list: the first model is taken" | — | reviewer, T || dispatch | anthropic | claude/sonnet | — |
| "a cell strike moves the walk to the next model in the list" | `harness-gave-up` on (anthropic, claude/sonnet) | reviewer, T, `attempt: 2` || dispatch | anthropic | claude/opus | — |
| "a model strike excludes the model, the list continues" | `no-verdict` on claude/sonnet | reviewer, T, `attempt: 2` || dispatch | anthropic | claude/opus | — |
| "a struck list moves the walk to the next rail" | `no-verdict` on claude/sonnet and on claude/opus | reviewer, T, `attempt: 3` || dispatch | opencode | opencode-go/claude-haiku-5-5 | — |
| "a strike is per task" | `no-verdict` on claude/sonnet for T | reviewer, another task || dispatch | anthropic | claude/sonnet | — |
| "a refuted strike excludes nothing" | `provider-5xx` (gateway) on claude/sonnet, then `clean` on that session | reviewer, T, `attempt: 2` || dispatch | anthropic | claude/sonnet | — |
| "a cooled cell in the list is skipped, the next model taken" | a 429 cooled (openrouter, deepseek/deepseek-v4-flash) | worker, `tier: light`, `rail: openrouter` || dispatch | openrouter | deepseek/deepseek-v4.1-flash | — |
| "every cell struck: cells-exhausted, no retry_after_s ⚖" | `no-verdict` on claude/haiku (prober: anthropic only, light) | prober, T, `attempt: 2` || defer (`{decision, reason}` only) | — | — | cells-exhausted |
| "a capacity-blocked rail outranks struck cells: the defer waits ⚖" | `no-verdict` on claude/sonnet and claude/opus; opencode at its 3 | reviewer, T, `attempt: 3` || defer | — | — | rail-capacity (60) |

| description | sequence || result |
|---|---||---|
| "attempt defaults to 1 and is on the row" | admit with no `attempt`, GET || `attempt` = 1 |
| "attempt below 1 is malformed" | `attempt: 0` || 400 malformed-body |
| "a re-admission of the same attempt supersedes the active one ⚖" | admit T `attempt: 1` twice (the same caller, unbound) || the first released (its token 401 `session-released`), the second active |
| "the next attempt does not supersede" | admit T `attempt: 1`, then `attempt: 2` || both active |
| "another pod's same attempt is not superseded" | admit T `attempt: 1` bound to fixer-1, then bound to fixer-2 || both active |
| "a re-run that restarts at attempt 1 still meets the task's strikes ⚖" | attempt 1 struck `no-verdict` on claude/sonnet and released; admit T `attempt: 1` again || dispatch claude/opus — undetectable as a re-run, excluded all the same |

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

Three per-rail checks and three per-cell checks after the slot count ([model-routing.md §The ladder](../../../docs/agents/model-routing.md#the-ladder--rail--class--tier--cell)'s
capacity facts, moved from the old proxy's two limit endpoints into the admission answer). Every
threshold, hold and anchor is policy data under `rails.<rail>.admission` — none is a code literal —
and each is ⚖ **copied** from the old proxy, which keeps serving its own copy until it retires
([§Who owns which fact](../../../docs/agents/model-routing.md#who-owns-which-fact): this is a
duplicate by design for that window, not a second owner). The Go rail's vendor facts — prices,
peak rows and hours, per-model monthly limits, window shares — are not policy: they are the
[Go catalog](../glossary.md#go-catalog)'s snapshot ([GW-CATALOG-GO](catalog.md#gw-catalog-go),
operator ruling 5, 2026-10-17). The per-cell checks walk the tier's ordered list: a model a check
holds is skipped for the next one, and only when every model is held does the rail defer, with the
hold that lifts first. A rail with no `admission` key has no
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
- **Cell cooldown** (every rail): an upstream 429 cools the **cell** — (rail, the session's policy
  model, provider) — until its reset, read from the wire: `retry-after` (delta seconds) first, then
  `x-ratelimit-reset` (OpenRouter sends the reset as epoch **milliseconds** and no `retry-after`),
  else the rail's `latch_429_hold_s`, else the policy's `defer_retry_s`. Admission skips a cooled
  cell (`cell-cooled`, `retry_after_s` = its reset); any 2xx on that cell clears it early — the old
  router's transport belt, which a 2xx also clears
  ([model-routing.md §The strike ladder](../../../docs/agents/model-routing.md#the-strike-ladder)).
  ⚖ The cell is (rail, model, provider): on the openrouter rail a 429 answered to a PINNED attempt
  cools that provider's cell only ([§The provider axis](#the-provider-axis-openrouter); the model
  admits while another eligible provider remains), an unpinned 429 cools the model's own cell
  (provider `''`) — the only cell on the rails that pin none. The evidence that a 429
  is a MODEL's fact, not the rail's: the 2026-10-17 free-model experiment
  (`docs/spikes/gateway-free-models-2026-10-17/cells.tsv`, 549 upstream responses) saw 115
  OpenRouter 429s across three models, each the model's own limit (`limit_source`
  `upstream_provider_shared_pool` 105, `openrouter_shared_capacity` 3,
  `openrouter_free_tier_per_minute` 7), while two other models on the same key served 200s
  throughout; an experiment rail latch on one model's 429 deferred a different model.
- **429 latch** (`anthropic`): the ACCOUNT-scope signal. ⚖ Scope is a property the policy
  declares, never inferred from a count: a rail whose policy sets `latch_429_hold_s` with
  `latch_scope: account` (the default) is one subscription account whose limits are account
  windows (the subscription's 5h/7d), so a 429 there latches the whole rail as well as cooling its
  cell, for the same reset (a reset-less 429 → the hold); any 2xx on the rail clears it early.
  ⚖ hold **900 s** = `ANTHROPIC_429_HOLD_S` (`openrouter-proxy.py`). `opencode` declares
  `latch_scope: model`: the vendor meters each Go model against **its own** monthly limit
  (operator ruling 3, [the spike §F2](../../../docs/spikes/opencode-go-catalog.md)), so a Go 429
  cools only its cell — for its reset, else the rail's `latch_429_hold_s` (**900 s** =
  `GO_CAPACITY_HOLD_S`) — and never blocks another Go model. `openrouter` declares none: its 429s
  are per model (the experiment above). A count rule ("≥ 2 models 429'd") would have latched it
  wrongly: two models' independent provider-pool 429s overlapped there while two others served.
- **Credential rejected** (every rail): an upstream 401, or a 403 whose error names a credential
  reason ([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary)), marks THAT credential —
  the rail plus a sha256 fingerprint of the value, never the value — rejected. Admission resolves
  the stack's credential as before and skips the rail when that credential is rejected; any 2xx on
  it clears it, and a changed value is a different fingerprint, so a rotation clears it by
  construction. A rejected credential **recovers without traffic**. A mark that only data-plane
  traffic could clear is a self-latch, because admission stops sending traffic once it is set. That
  happened live on 2026-10-17: an edge's 403 latched the Go rail until a pod restart.
  ⚖ A rail whose policy declares **`credential_probe`** (`{method, path, body?, backoff_s:
  [first, cap]}`, relative to the rail's upstream base) is re-verified by the gateway itself. A
  background loop re-resolves the credential through the stack that saw it (a changed value clears
  the mark) and sends the probe with it, on a doubling backoff. Only a 2xx clears the mark. A
  credential verdict doubles the backoff. Anything else (5xx, unreachable, an edge refusal) is no
  verdict and is retried at the same backoff.
  - opencode probes with `POST /v1/chat/completions`, one token on the rail's model. Its
    `/v1/models` answers 200 to no key at all, and a bogus model fails before the key is checked
    (both probed live), so neither proves the key.
  - openrouter probes with `GET /v1/key`, which costs nothing.
  - ⚖ A rail with **no probe** (anthropic: no free authenticated call on the subscription) is
    re-admitted **half-open** after `credential_hold_s` (**900 s**): the next ride is the probe, and
    a fresh rejection doubles the hold.
  A walk blocked only by rejected credentials defers `credential-rejected` with `retry_after_s` =
  the earliest re-verification. ⚖ The marks live in memory: a restart forgets them, and the next
  rejection re-marks. Nothing unverified is carried across a restart. A policy refusal or an edge
  refusal ([GW-CRED-BOUNDARY](anthropic-messages.md#gw-cred-boundary)) rejects nothing.
- **Go window draw** (`opencode`, per cell): each `window_draw.windows.<w>` (`5h` / `7d` / `30d`)
  sums the **model's** metered (2xx) requests inside the window open at `now`, priced from the
  four token classes at the Go catalog's **list** rates — uncached input and output at `in`/`out`,
  each cache class at its own rate (a `null` rate draws nothing); the model's peak row inside a
  peak hour by the REQUEST's timestamp; else the cost tier the request's prompt (uncached + cache
  read + cache write tokens) exceeds — gometer's `window_draw()` semantics. A window at/over
  `threshold × monthly limit × share` holds that model until the window resets, where the monthly
  limit is the model's own under `rails.opencode.plan` and the share is the page's (5h 20 % ·
  weekly 50 % · monthly 100 % today). ⚖ The rules stay copied from `gometer.py`: the anchors
  (`_GO_WINDOW_DEFAULTS`: 5h `chain` · 7d `weekly` Mon 00:00 · 30d `monthly` 13th 11:30 —
  self-measured, no vendor source) and `OPENCODE_UTIL_THRESHOLD`'s 0.80. The `chain` window opens
  at the model's first request after its previous one expired (`router.go_usage_chain_open`).
  Prices apply at READ time from the ledger (`requests` × `sessions.model`), so a catalog refresh
  re-prices the open windows. A model whose monthly limit is `unlimited` draws against no window.
- **Not in the catalog** (`opencode`, per cell): a Go model the catalog's config snapshot does not
  list, or that has no monthly-limit row under the policy's plan (or no snapshot exists yet), is
  refused — `not-in-catalog`, `retry_after_s` = the next scheduled catalog refresh — never priced at
  a fallback (operator ruling 4). This is the 2026-10-14 retirement (the spike's §F3) turned from
  silent into a typed defer.

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
| "a Go 429 cools only its cell, for its retry-after" | worker ride on opencode → 429 | — | worker, `rail: opencode` || defer | — | cell-cooled | 30 |
| "a Go 429 without retry-after cools its cell for the rail's hold" | worker ride on opencode → 429, no `retry-after` | — | worker, `rail: opencode` || defer | — | cell-cooled | 900 |
| "one Go model's 429 never blocks another Go model" | worker ride on opencode → 429 (`deepseek-v4.1-flash`) | — | worker, `rail: opencode`, `tier: heavy` (`claude-haiku-5-5`) || dispatch | opencode | — | — |
| "a cooled Go cell is skipped, the walk continues" | worker ride on opencode → 429 | — | worker (policy walk) || dispatch | openrouter | — | — |
| "a rail whose policy declares no latch is not latched: its other model admits ⚖" | worker ride on openrouter → 429 | — | worker, `rail: openrouter`, `tier: heavy` || dispatch | openrouter | — | — |
| "every rail blocked: the rail that frees first names the defer ⚖" | worker ride on opencode → 429; openrouter at its 20 | — | worker (policy walk) || defer | — | cell-cooled | 30 |

The cell rows ride `upstream-429-reset` — OpenRouter's shape, `x-ratelimit-limit` / `-remaining` /
`-reset` (epoch ms) and no `retry-after` — unless stated. A worker on openrouter rides the standard
tier's `deepseek/deepseek-v4-flash`; its heavy tier is `deepseek/deepseek-v4.1-flash`.

| description | arrange | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| "a 429 cools its cell until x-ratelimit-reset (epoch ms)" | worker ride on openrouter → 429, reset T0 + 42 s | — | worker, `rail: openrouter` || defer | — | cell-cooled | 42 |
| "retry-after outranks x-ratelimit-reset" | the same, plus `retry-after: 30` | — | worker, `rail: openrouter` || defer | — | cell-cooled | 30 |
| "a 429 that names no reset cools for defer_retry_s ⚖" | worker ride on openrouter → 429, no header | — | worker, `rail: openrouter` || defer | — | cell-cooled | 60 |
| "another model on the rail is not cooled" | worker ride on openrouter → 429, reset T0 + 42 s | — | worker, `rail: openrouter`, `tier: heavy` || dispatch | openrouter (`deepseek/deepseek-v4.1-flash`) | — | — |
| "the cell admits again at its reset" | worker ride on openrouter → 429, reset T0 + 42 s | +42 s | worker, `rail: openrouter` || dispatch | openrouter | — | — |
| "a 2xx on the cell clears it" | worker ride on openrouter → 429, the same session → 200 | — | worker, `rail: openrouter` || dispatch | openrouter | — | — |
| "a cooled cell is skipped, the walk continues" | researcher ride on openrouter → 429 (the heavy cell) | — | researcher, `harness: claude` (policy walk) || dispatch | anthropic | — | — |
| "a subscription 429 latches the rail and cools the cell: the latch names the defer ⚖" | reviewer ride on anthropic → 429 (`retry-after: 30`) | — | reviewer, `rail: anthropic` || defer | — | rail-latched | 30 |

The credential rows arrange an upstream 401 (`upstream-401`, or the Go vendor's
`upstream-401-key-expired`) or OpenRouter's harness-gate 403 (`upstream-403-refused`) on one ride.

| description | arrange | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| "a rejected credential is skipped, the walk continues" | worker ride on opencode → `upstream-401-key-expired` | — | worker (policy walk) || dispatch | openrouter | — | — |
| "every allowed rail's credential rejected defers credential-rejected ⚖" | prober ride on anthropic → `upstream-401` | — | prober (policy walk) || defer | — | credential-rejected | 900 (the half-open hold) |
| "a rejection is per credential: another stack's key still admits" | platform worker ride on openrouter → `upstream-401` | — | oracle worker, `rail: openrouter` (its own key) || dispatch | openrouter | — | — |
| "a new credential value clears it" | platform worker ride on openrouter → `upstream-401`; the Secret then holds a new key | +301 s (the ref cache) | worker, `rail: openrouter` || dispatch | openrouter | — | — |
| "a 2xx on the credential clears it" | platform worker ride on openrouter → `upstream-401`, the same session → 200 | — | worker, `rail: openrouter` || dispatch | openrouter | — | — |
| "a policy refusal does not reject the credential" | worker ride on openrouter → `upstream-403-refused` | — | worker, `rail: openrouter` || dispatch | openrouter | — | — |

The recovery rows. The probe pass is the app's background loop, called here directly
(`proxy.reprobe()`) on the test clock. `policy-default`'s opencode probe is `POST
/v1/chat/completions` (1 token, backoff `[60, 3600]`). Anthropic declares none (hold 900 s).

| description | arrange | then | probe answers || probes sent | decision | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| "a probe's 2xx clears a rejected credential without traffic" | worker ride on opencode → `upstream-401-key-expired` | +60 s, re-probe | upstream-ok || 1 | dispatch (opencode) | — | — |
| "a probe rejected again doubles the backoff" | the same | +60 s, re-probe | upstream-401-key-expired || 1 | defer | credential-rejected | 120 |
| "a probe with no verdict keeps the backoff ⚖" | the same | +60 s, re-probe | upstream-500 || 1 | defer | credential-rejected | 60 |
| "a probe is not sent before it is due" | the same | +30 s, re-probe | — || 0 | defer | credential-rejected | 30 |
| "a rail with no probe is re-admitted half-open after its hold ⚖" | prober ride on anthropic → `upstream-401` | +900 s | — || 0 | dispatch (anthropic) | — | — |
| "a repeat rejection after half-open doubles the hold" | prober on anthropic → 401; +900 s; → 401 again | — | — || — | defer | credential-rejected | 1800 |
| "an edge refusal marks nothing: the rail keeps admitting" | worker ride on opencode → `upstream-403-edge` (`error code: 1010`) | — | — || 0 | dispatch (opencode) | — | — |

The Go rows ride the world's Go catalog (`catalog-ok` + `docs-ok`, plan `go` —
[worlds/README.md §The Go catalog's fakes](../worlds/README.md#the-go-catalogs-fakes)). A worker
ride on opencode rides `opencode-go/deepseek-v4.1-flash`: base in 0.15 / out 0.60 / cache_read
0.003 / cache_write `null`, peak 0.30 / 1.20 / 0.006 / `null`, $80 a month → windows $16 / $40 /
$80, thresholds $12.80 / $32 / $64. A reviewer ride (or a worker's `tier: heavy`) rides
`opencode-go/claude-haiku-5-5`: base 0.10 / 0.50 / 0.01 / 0.125, above 100000 prompt tokens
0.50 / 2.50 / 0.05 / 0.625, no peak row, $15 a month → 5h threshold $2.40. The expected value of
each row is computed in its test's comment.

| description | ride usage (at) | then | body || decision | rail | reason | retry_after_s |
|---|---|---|---||---|---|---|---|
| "a 5h draw over threshold defers the Go model until its window resets" | worker in 30M, out 3.2M (T0) — $12.84 | — | worker, `rail: opencode` || defer | — | rail-window | 18000 |
| "a 5h draw under threshold admits" | worker in 30M, out 3.1M (T0) — $12.72 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "an off-peak request draws at the base rate" | worker in 30M, out 3.2M (T0 + 2 h) — $6.42 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "cache reads draw at their own rate, not the input rate" | worker cache_read 1000M (T0) — $6.00, not $300 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "a cache class with no rate draws nothing ⚖" | worker cache_write 1000M (T0) — $0 | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "a prompt past the context tier draws at the tier's rate ⚖" | reviewer in 4M, out 0.2M (T0) — $2.50 (the base row: $0.50) | — | worker, `rail: opencode`, `tier: heavy` || defer | — | rail-window | 18000 |
| "a prompt within the context tier draws at the base row ⚖" | reviewer in 90K, out 1M (T0) — $0.509 (the tier row: $2.545) | — | worker, `rail: opencode`, `tier: heavy` || dispatch | opencode | — | — |
| "each model's windows are its own monthly limit's shares" | worker in 10M, out 1M (T0) — $4.20 (under its $12.80; haiku's $2.40 would hold it) | — | worker, `rail: opencode` || dispatch | opencode | — | — |
| "a full window on one Go model never blocks another" | worker in 30M, out 3.2M (T0) | — | worker, `rail: opencode`, `tier: heavy` || dispatch | opencode | — | — |
| "the walk continues past a full Go window" | worker in 30M, out 3.2M (T0) | — | worker (policy walk) || dispatch | openrouter | — | — |
| "an expired 5h window draws nothing" | worker in 30M, out 3.2M (T0) | +18000 s | worker, `rail: opencode` || dispatch | opencode | — | — |
| "the 7d window binds once the 5h one has expired" | worker in 110M (T0) — $33 | +18000 s | worker, `rail: opencode` || defer | — | rail-window | 212400 |
| "the 30d window binds once the week has reset" | worker in 220M (T0) — $66 | +230401 s | worker, `rail: opencode` || defer | — | rail-window | 2287799 |

The catalog rows refresh the world's Go catalog against the fake vendor first: `catalog-retired`
(the catalog — models.dev — without `deepseek-v4.1-flash` — §F3 replayed) or `docs-retired` (the Go page
without `claude-haiku-5-5`'s plan rows). `retry_after_s` = the next scheduled refresh (21600 s
after the one just run).

| description | the refresh | body || decision | rail | reason | retry_after_s |
|---|---|---||---|---|---|---|
| "a Go model the catalog no longer lists defers not-in-catalog ⚖" | `catalog-retired` | worker, `rail: opencode` || defer | — | not-in-catalog | 21600 |
| "a not-in-catalog model is skipped, the walk continues ⚖" | `catalog-retired` | worker (policy walk) || dispatch | openrouter | — | — |
| "a listed model with no monthly limit under the plan defers not-in-catalog ⚖" | `docs-retired` | worker, `rail: opencode`, `tier: heavy` || defer | — | not-in-catalog | 21600 |
| "the other Go models still admit ⚖" | `catalog-retired` | worker, `rail: opencode`, `tier: heavy` || dispatch | opencode | — | — |
| "no catalog snapshot at all: every Go model is not-in-catalog ⚖" | none — a fresh store, no refresh yet | worker, `rail: opencode` || defer | — | not-in-catalog | 60 (`defer_retry_s`: no refresh is scheduled yet) |

### The provider axis (openrouter)

Once the endpoint snapshot covers a model ([GW-RAIL-OPENROUTER §Selection](openai-chat.md#selection--the-gateways-own-evidence-never-exacto),
homelab#2741), the openrouter [cell](../glossary.md#cell) is `(rail, model, provider)`: a cell-scoped
strike or a 429 cooldown on one provider leaves the model admissible while another eligible
provider remains; the model is **exhausted** for the task when every eligible provider is struck,
**cell-cooled** (until the earliest reset) when every remaining one is cooled, and ⚖
**`no-eligible-provider`** (a typed defer, `retry_after_s` = `defer_retry_s`) when the snapshot
covers the model but no endpoint clears the policy floors — the model is not ridden, the walk
continues. ⚖ A provider-scoped strike on a model the snapshot does NOT cover excludes the model's
cell: nothing can route around it. The rails that pin no provider keep provider `''`.

World `policy-default · openrouter-endpoints` (the snapshot of `deepseek/deepseek-v4.1-flash` = M, the
openrouter heavy tier; `deepseek/deepseek-v4-flash` = the standard tier has no entry);
`openrouter-endpoints-ineligible` = the snapshot trimmed to open-inference/fp4, alibaba and
parasail/fp8, none of which clears the floors ([worlds/README.md](../worlds/README.md#the-openrouter-endpoints-world)).

| description | arrange | body || decision | rail | model | reason | retry_after_s |
|---|---|---||---|---|---|---|---|
| "a provider cell strike leaves the model admissible while another eligible provider remains ⚖" | T's earlier ride struck `harness-gave-up` on deepinfra | worker, `rail: openrouter`, `tier: heavy`, T || dispatch | openrouter | M | — | — |
| "every eligible provider struck for the task: the model is exhausted ⚖" | T's five earlier rides struck deepinfra, atlas-cloud, morph, inference-net, baidu | worker, `rail: openrouter`, `tier: heavy`, T || defer (`{decision, reason}` only) | — | — | cells-exhausted | — |
| "every eligible provider cooled: cell-cooled until the earliest reset ⚖" | two requests whose pinned attempts all answered 429 (`retry-after: 30`) | worker, `rail: openrouter`, `tier: heavy` || defer | — | — | cell-cooled | 30 |
| "no endpoint clears the floors: the model defers no-eligible-provider ⚖" | `openrouter-endpoints-ineligible` | worker, `rail: openrouter`, `tier: heavy` || defer | — | — | no-eligible-provider | 60 |
| "an ineligible model is skipped, the walk continues" | `openrouter-endpoints-ineligible` | researcher, `harness: claude` (rails openrouter, anthropic) || dispatch | anthropic | claude/sonnet | — | — |
| "a provider strike with no snapshot to steer by excludes the model's cell ⚖" | T's unpinned v4-flash ride (served by Sail Research) struck `harness-gave-up` | worker, `rail: openrouter`, `tier: standard`, T || defer (`{decision, reason}` only) | — | — | cells-exhausted | — |

### Named gaps (rows that exist so the omission is visible)

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: FU-109 tier thresholds" | a dispatch-unit tier asking past the 5h threshold || deferred at the per-window threshold | the old proxy RAISES a window's threshold per consumer tier (`model-classes.json` `tier_thresholds`); the gateway's `light`/`standard`/`heavy` is not that vocabulary |
| "⚑ gap: a latch survives a restart" | a 429 latch, a cooled cell or a rejected credential, then a gateway roll || forgotten; the next 429 / 401 marks it again | the old proxy persists its latches (`router.latch_save`); these are in memory |
| "⚑ gap: the OpenRouter account latch" | 402s / credit below the floor on a stack key || no latch | the old proxy's `rpd` / `credit` / hard-402 legs (homelab#158) and the key headroom poll ([GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter)); cross-model 429s are per-cell facts here (§Capacity), not an account signal |
| "⚑ gap: the free-tier key budget spans every `:free` cell" | a 429 whose body says `limit_source: openrouter_free_tier_per_minute` || only the cell that saw it cools; the next `:free` cell 429s once and cools itself | the limit is the key's across `:free` models (20 req/min in the experiment's headers); reading the body's `limit_source` would cool them as one group — not built |
| "⚑ gap: a Go 402" | an upstream 402 on opencode || no latch | the old proxy latches a Go 402 for `GO_CAPACITY_402_HOLD_S` (1800 s) |
| "⚑ gap: the Go draw is the gateway's own traffic only" | Go spend through the old proxy or the jail shim || not in this ledger — this draw is a lower bound of the account's | the account-wide reading (the old proxy's ledger, the jail shim's reports) |
| "⚑ gap: one model across rails" | a model strike on `claude/sonnet` || `opencode-go/claude-haiku-5-5` still admits | the policy names rail-prefixed ids; `model-classes.json` groups them per model, and that grouping is not in the gateway policy |
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
  `model: deepseek-v4.1-flash` on every request. So opencode's env is that ONE var.

The model var carries the policy id with its rail prefix removed (`claude/sonnet` →
`sonnet`, `opencode-go/deepseek-v4.1-flash` → `deepseek-v4.1-flash`; openrouter ids are bare) — the
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
| "claude on the [Go rail](../../../docs/agents/chainless-redesign.md): same three vars, Go's model name" | claude | opencode | opencode-go/claude-haiku-5-5 || `ANTHROPIC_MODEL` | `claude-haiku-5-5` |
| "opencode: an openai-compatible provider block" | opencode | opencode | opencode-go/deepseek-v4.1-flash || `OPENCODE_CONFIG_CONTENT` → `.provider.gateway.npm` | `@ai-sdk/openai-compatible` |
| "opencode: the provider's base url is this gateway's openai path" | opencode | opencode | opencode-go/deepseek-v4.1-flash || `OPENCODE_CONFIG_CONTENT` → `.provider.gateway.options.baseURL` | `http://agent-gateway.agent-egress.svc.cluster.local:8080/openai/v1` |
| "opencode: the provider's api key is the session token" | opencode | opencode | opencode-go/deepseek-v4.1-flash || `OPENCODE_CONFIG_CONTENT` → `.provider.gateway.options.apiKey` | the session token |
| "opencode: the session model is the bare id under that provider" | opencode | opencode | opencode-go/deepseek-v4.1-flash || `OPENCODE_CONFIG_CONTENT` → `.model` | `gateway/deepseek-v4.1-flash` |
| "opencode: the title model is the same id" | opencode | opencode | opencode-go/deepseek-v4.1-flash || `OPENCODE_CONFIG_CONTENT` → `.small_model` | `gateway/deepseek-v4.1-flash` |
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
| "a declared `context_tokens` is echoed" | opencode-go/deepseek-v4.1-flash || 1000000 |
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
| "GET returns the row without the token" | dispatch → `GET /sessions/{id}` || 200; `id, stack, role, task, round, attempt, rail, harness, model, created_at, expires_at, released_at, requests, tokens_in, tokens_out, tokens_cache_read, tokens_cache_write, caller, requests_incomplete, outcome, state, release_reason` (`state` / `release_reason`: [GW-SESSIONS-LIVENESS](#gw-sessions-liveness); `outcome`: the latest reported outcome, [GW-SESSIONS-OUTCOME](#gw-sessions-outcome); `requests_incomplete`: the 2xx answers whose body stopped before its end, [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter); the admitting caller, [GW-SESSIONS-AUTH](#gw-sessions-auth); `null` here — the row's caller sent no token under `observe`); no `token`, no `token_hash` |
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
so a codex harness can point that command at this endpoint after its initial full env pull.

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
| "the pull answers the opencode env GW-SESSIONS-ENV would have" | worker (opencode) bound → pull || `env` keys = `env_keys`; the provider `apiKey` is a fresh `^gws_[A-Za-z0-9_-]{32}$`; `baseURL` `…/openai/v1`, model `gateway/deepseek-v4.1-flash` |
| "the pull answers the claude env" | reviewer (claude) bound → pull || `ANTHROPIC_AUTH_TOKEN` a fresh `gws_` token, `ANTHROPIC_BASE_URL` `…/anthropic`, `ANTHROPIC_MODEL` `sonnet` |
| "the pull answers the goose env" | worker goose/openrouter bound → pull || `OPENAI_API_KEY` a fresh `gws_` token, `OPENAI_BASE_URL` `…/openai/v1`, `GOOSE_PROVIDER` `openai`, `GOOSE_MODEL` `deepseek/deepseek-v4-flash` |
| "the pulled token rides the data plane" | pull → `POST /openai/v1/chat/completions` with it (`upstream-ok`) || 200; the row's `requests` = 1 |
| "the row stores the pulled token's sha256 only" | pull, read the DB || `token_hash` = sha256(token); the token appears nowhere in the sqlite dump |

### Codex token re-read (GW-SESSIONS-PULL / GW-SESSIONS-ENV)

After the first full env delivery, a Codex pull returns **only a fresh session token** as
`text/plain` with `Cache-Control: no-store`. It never returns configuration again.
TokenReview runs every time. ⚖ Re-read requires the first pull's exact pod name AND UID;
missing UID fails closed, even if namespace/ServiceAccount/name match. Every successful re-read
atomically replaces the stored token hash; the old token stops authenticating immediately.
Release and expiry are checked before rotation and again in the conditional write. A racing
rotation returns 409 `token-rotation-conflict` and may be retried. Other harnesses stay once-only.
The wrapper performs its initial full env pull before starting Codex; its `auth.command` can
then print this endpoint's plain token. No upstream OAuth credential reaches the pod.

| description | second pull || answer |
|---|---||---|
| "same pod rotates token only" | same UID || plain token, old invalid |
| "recreated pod is refused ⚖" | different UID || 403 |
| "absent UID cannot reread ⚖" | missing UID || 403 |
| "released session cannot reread" | released || 401 |
| "expired session cannot reread" | expired || 401 |

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
| "⚑ gap: a racing rotation" | two concurrent same-pod re-reads || one plain token, one 409 `token-rotation-conflict` (the conditional write) | unexercised: the ASGI test client serializes the two pulls, so the conflict arm has no row — it rides with the first concurrent fixture |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-PULL.md"

</details>

## GW-SESSIONS-LIVENESS

*A session whose pod is gone is reaped* (operator ruling 2026-10-17, FU-270). A ride whose pod is
SIGKILLed never sends its DELETE, and without liveness its session would hold the rail slot until the
TTL. The 2026-10-17 experiment's probe left one active for its whole TTL
(`docs/spikes/gateway-free-models-2026-10-17/cells.tsv`, probe-c: `released_at: null` at
expiry). The gateway already knows the pod first-hand, from the TokenReviews it does anyway:
- a **bound** session's pod is the one whose projected token pulled its env
  ([GW-SESSIONS-PULL](#gw-sessions-pull)); the review names the pod and its uid;
- an **unbound** session's pod is its **caller's**, when the caller's projected token is pod-bound
  ([GW-SESSIONS-AUTH](#gw-sessions-auth); the same extras).

⚖ **A pod check, not a TTL-with-renewal.** The pod check is one namespaced `pods get` per live
session per pass. The cost is a reaper interval (`liveness_check_s`, **60 s**) times the active
sessions (≤ 28 today, the rails' caps summed) GETs, so at most about 28 requests a minute to the
kube API. A renewal protocol would put a heartbeat into every consumer and every harness wrapper,
and still lose the session when the heartbeat process itself is what died. The RBAC is a namespaced
`agent-gateway-session-pods` Role (`pods: get`) in each bind namespace and each caller namespace
(`argocd/resources/agent-gateway/rbac.yaml`). It adds no cluster-scoped name.

A pass releases a session whose pod is **gone** (404), **terminal** (`Succeeded` / `Failed`), or
**another pod under the same name** (a different uid: the launcher re-creates a retried ride's pod
with the same name). The release has `release_reason: pod-gone`, the slot frees, the token is refused
from then on, and `gateway_sessions_reaped_total{rail}` goes up by 1. ⚖ A pod the API cannot answer
for (5xx, unreachable, no Role in that namespace) is left to its TTL: an unknown is never a reap.
Sessions with no known pod are left to the TTL as well: a bound session not yet pulled, or an
unbound session whose caller token is not pod-bound (a jail canary's minted token).

`GET /sessions/{id}` now says which state the session is in. **`state`**: `active` | `released` |
`expired` — the data plane's verdict ([GW-SESSIONS-RELEASE](#gw-sessions-release): the older fact
wins). **`release_reason`**: `released` (a DELETE) | `superseded` (a re-admission of the same attempt,
[§The retry contract](#the-retry-contract--model-lists-strikes-attempt)) | `pod-gone`. It is null
while the session is not released. An expired session therefore reads `state: expired`, where before
it showed only `released_at: null`.

World `policy-default`; the pods API is the fake `StaticPods` (every pod running unless the row says
otherwise); the pass is `sessions.reap()` (the app's background loop in production).

| description | session | the pods API answers || state | release_reason |
|---|---|---||---|---|
| "a bound session whose pod is gone is reaped" | bound, pulled by fixer-1 | fixer-1: 404 || released (its token 401 `session-released`, the slot freed) | pod-gone |
| "a terminal pod is reaped" | bound, pulled by fixer-1 | fixer-1: phase `Succeeded` || released | pod-gone |
| "a re-created pod under the same name is reaped ⚖" | bound, pulled by fixer-1 (uid-1) | fixer-1: running, uid-2 || released | pod-gone |
| "a running pod keeps its session" | bound, pulled by fixer-1 | fixer-1: running, uid-1 || active | null |
| "a pod the API cannot answer for is left to the TTL ⚖" | bound, pulled by fixer-1 | unknown (5xx / no Role) || active | null |
| "a bound session not yet pulled is not checked ⚖" | bound, never pulled | (0 calls) || active | null |
| "an unbound session lives in its caller's pod ⚖" | unbound, the caller's token pod-bound to `specs-review-tick` | `specs-review-tick`: 404 || released | pod-gone |
| "a caller token with no pod binding is left to the TTL ⚖" | unbound, the caller's token not pod-bound (minted) | (0 calls) || active | null |

| description | sequence || (state, release_reason, released) |
|---|---||---|
| "an active session says active" | admit, GET || (active, null, no) |
| "a released session says why" | admit, DELETE, GET || (released, released, yes) |
| "an expired session says expired, not a null release" | admit, the clock past `expires_at`, GET || (expired, null, no) |
| "a superseded session says so" | admit attempt 1 twice (the same caller, unbound), GET the first || (released, superseded, yes) |

| description | sequence || result |
|---|---||---|
| "a reap is counted on its rail" | a bound opencode session reaped (its pod gone) || `gateway_sessions_reaped_total{rail="opencode"}` = 1 |
| "one pods API call per live session per pass" | three pulled bound sessions, one pass || 3 calls |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-LIVENESS.md"

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
It counts in both modes. The deployed policy ran in `observe` until every caller sent its token
and the series stayed flat, then flipped to `enforce` (2026-10-17); `observe` stays the rollback knob. ⚖ **A VALID token is checked against `callers`
in both modes.** Under `observe`, a caller the gateway can identify but that is unlisted, or that
asks outside its entry, is refused exactly as under `enforce`. The knob forgives a missing identity
during the rollout. It never waves through a known identity the policy does not grant.

Rows run against two worlds. **`policy-default`** is `observe`, so every other row on this page
runs unchanged without a caller token. **`policy-enforce`** is the same document with `enforce`
([worlds/README.md](../worlds/README.md)). Both hold three fixture callers; the third, the judge,
admits nothing and is [GW-SESSIONS-OUTCOME](#gw-sessions-outcome)'s.
**The platform loop** = `system:serviceaccount:platform-agents:agentstack-loop` · stacks
`[platform]` · roles `[worker, prober]` (the dispatcher's workers, and the entry canary's prober
rides — [GW-CATALOG-OR §The entry canary](catalog.md#the-entry-canary) — which `canary-entrants.sh`
admits as this SA) · bind namespaces `[platform-agents]`. **The specs reviewer** =
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
| "the entry canary's role is inside the dispatcher's entry ⚖" | the platform loop | platform `prober`, no bind || 200 | `dispatch` — the caller check passes; the deployed `callers` grants the dispatcher SA `prober` beside `worker` (2026-10-20: without it every canary admission was 403, no openrouter cell could become eligible) |
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
| "the deployed callers are today's two dispatchers, under enforce" | `argocd/resources/agent-gateway/policy.json` || loads; `control_plane_auth` = `enforce`; `callers` = exactly `system:serviceaccount:platform-agents:agentstack-loop` (stacks `[platform]`, roles `[worker, prober]`, bind namespaces `[agent-runtime, homelab, openrouter-operator]`) and `system:serviceaccount:agent-coordinator:specs-review` (`[platform]`, `[reviewer, worker]`, `[]`) |

The deployed entries are today's in-cluster callers, named by the SA they run as. The platform
stack's graduated coordinator pod (`agents/coordinator-session.sh --loop-ns`, SA `agentstack-loop`)
is the one in-cluster caller of `agents/agent-session.sh`; the jail's `canary-entrants.sh` mints
the same SA's token to ride the entry canary, which is why its entry grants `prober` beside
`worker` (2026-10-20 — until then every canary admission was 403 `caller-role-denied`). It binds
into the platform repo namespaces that hold an `agentstack-worker` SA. ⚖ `agent-coordinator` is a platform repo but holds
no `agentstack-worker`, so a bind there could never be pulled and is not granted. The specs-review
tick and its shadow cells run as their own SA `specs-review` (`agents/coordinator/specs-review-argo.yaml`;
homelab#2685 — `callers` is per SA, and `agent-coordinator` is the SA every other workflow in that
namespace shares): role `reviewer`, plus ⚖ `worker` for the goose@openrouter shadow cell, which rode `--role worker`
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

## GW-SESSIONS-OUTCOME

*The consumer classifies its own output; the gateway owns what it sees first-hand; one store, one
vocabulary* (operator ruling 2026-10-17, FU-270). `POST /sessions/{id}/outcome {class, subclass?,
evidence?}` is how a consumer says how its ride ended. The gateway can see a 429, a 401 or a cut
stream ([§Capacity](#capacity--the-ladders-capacity-half)), but not a review that returned no
verdict, or one that invented its findings — the 2026-10-17 free-model experiment
(`docs/spikes/gateway-free-models-2026-10-17/cells.tsv`) had both behind clean 200s. The caller
check is [GW-SESSIONS-AUTH](#gw-sessions-auth)'s with the DELETE rule: the admitting caller may
report. ⚖ A **judge** may report too: a `callers` entry with `outcome: any` may report on any
session of its `stacks`, which a later check (did the APPROVE hold?) needs, since the reviewer
cannot grade its own verdict. The key is optional and `own` by default, so an absent key grants
nothing extra. The deployed policy lists no judge.

⚖ **When:** before release, and after release or expiry for the policy's `outcome_window_s`
(**86400 s**). The launcher reports before its DELETE; a judge reads a verdict's fate later, so a
pre-release-only rule would have no place for `wrong-verdict`. ⚖ **Once per reporter:** the same
class again is a replay (200, `replay: true`, nothing new stored); a different class from the same
reporter is 409 `outcome-conflict`; a judge's outcome is another reporter's and supersedes on
`GET` (`outcome` = the latest). The checks run in a fixed order: the caller (401 / 403 / 503), the
id (404), owner or judge (403 `caller-not-owner`), the body (400), a judge-only class (403), the
window (409), the reporter's earlier class (409).

**Rounds ≠ strikes** ([model-routing.md §The design's three rules](../../../docs/agents/model-routing.md#the-designs-three-rules)):
a logic failure, a reviewer's `CHANGES_REQUESTED` or CI red on the change, is a ROUND, owned by
the consumer's round counter. It is **no class here**, and saying one is 400
`outcome-class-unknown`. An infra or serving failure is a STRIKE.

### The vocabulary — one home

`sessions.schema.json` `outcome.input.properties.class` (`enum` + `x-scope`) is the set; the code's
copy (`outcomes.py` `OUTCOME_CLASSES`) is pinned to it by a row. **Scope** is the old router's rule
([model-routing.md §The strike ladder](../../../docs/agents/model-routing.md#the-strike-ladder)): a
**cell**-scoped (serving-shaped) strike excludes that (rail, model, provider) [cell](../glossary.md#cell) for
the task; a **model**-scoped one excludes the model on every rail for the task. ⚖ Each new class's
scope is a judgment, marked.

| class | scope | who writes it | what it means |
|---|---|---|---|
| `clean` | — | consumer | the ride did its job; refutes the task's counted strikes on this cell / model |
| `harness-death` | model | consumer | the harness died (goose `-32602` and kin) |
| `auth-storm` | cell | consumer · **gateway** (an upstream 424 `upstream-auth`) | 401/403 from the serving upstream |
| `timeout` | cell | consumer · **gateway** (504, or a stream cut by a read timeout) | the completion timed out at the provider |
| `provider-5xx` | cell | consumer · **gateway** (an upstream 5xx relayed, or 502 `upstream-unreachable`) | the provider failed |
| `no-pr` | model | consumer | the ride produced no artifact |
| `unknown` | model | consumer | an unclassified death |
| `turn-cap` | model | consumer | the ride died at a turn / output cap |
| `tool-loop` | cell | consumer | a cap death with zero tool-result progress |
| `no-verdict` | model ⚖ | consumer | a review ride ended without a verdict; the experiment's no-verdict behind an all-200 ride was the model's (nemotron on #2640: 16 × 200, then the 600 s cap) — the serving ones carry their own transport strike |
| `wrong-verdict` | model | **judge only** | the verdict did not hold under a later check — the experiment's judged-WRONG verdicts: inkling's APPROVE on #2640, cohere's on #2628 and #2635 |
| `invented-findings` | model ⚖ | consumer | a review cited defects the diff does not contain |
| `repetition` | model ⚖ | consumer | the model looped on its own output |
| `harness-gave-up` | cell ⚖ | consumer | the harness abandoned after the upstream kept failing (retries exhausted) — a serving shape |
| `stream-incomplete` | cell ⚖ | **gateway** (a 2xx with `incomplete` = `no-terminal` / `transport-error`) | the stream ended before its terminal event |
| `refused` | cell ⚖ | **gateway** (403 `upstream-refused`) | the upstream refused this model for this caller (OpenRouter's harness gate) |

### The store

A strike is a row keyed **(stack, task, rail, model, provider)** with its class, scope and
**source** (`outcome` = the consumer, `gateway` = a transport fact); `provider` is the serving
provider's slug on the openrouter rail ([GW-RAIL-OPENROUTER §Attribution](openai-chat.md#attribution--the-answer-names-the-cell)),
`''` where none was named — a cell-scoped class lands on the provider(s) the ride rode, a
model-scoped one carries none. ⚖ At most one per
(session, class, source, provider): nine 502s on one ride are one `provider-5xx`, not nine — and a
failed-over ride strikes each provider it tried, one per cell. ⚖ A 429 writes
**no** strike: the cell cooldown is that fact's whole answer, and a rate limit says nothing about
this task. ⚖ A pod that hung up (`client-closed`) writes none either: why it hung up is the
consumer's to say. **A clean outcome refutes** the task's counted strikes on the same cell
(cell-scoped) and the same model (model-scoped): they stay as history, with `refuted_at` set.
**A bare 2xx refutes nothing**: a provider serving badly behind HTTP 200 is exactly what a strike
routes around (the old router's refutation rule). ⚖ A clean outcome refutes cell strikes only on
the cells the ride rode CLEAN (the providers that served it a 2xx, and the model's own cell): a
provider the ride failed over from keeps its strike. `gateway_strikes_total{class,source}` counts
them ([GW-METRICS](metrics.md#gw-metrics)).

### Who may report

Fixture callers: the platform loop, the specs reviewer and **the judge**
(`system:serviceaccount:agent-coordinator:outcome-judge` · stacks `[platform]` · roles `[]` ·
`outcome: any`). A worker session = the platform loop admitted `{platform, worker, task
homelab-2700, round 1}` (opencode, `opencode-go/deepseek-v4.1-flash`).

| description | world | reporter | body || status | result |
|---|---|---|---||---|---|
| "the admitting caller reports an outcome" | policy-enforce | the platform loop | `no-verdict` || 200 | `strike` `{no-verdict, model}` |
| "another listed caller may not" | policy-enforce | the specs reviewer | `no-verdict` || 403 | caller-not-owner |
| "a judge may report on a session it did not admit ⚖" | policy-enforce | the judge | `wrong-verdict` || 200 | `strike` `{wrong-verdict, model}` |
| "wrong-verdict is a judge's call ⚖" | policy-enforce | the platform loop | `wrong-verdict` || 403 | outcome-judge-only |
| "no bearer, under enforce" | policy-enforce | no bearer | `no-verdict` || 401 | caller-unauthenticated |
| "an unknown id after the caller check" | policy-enforce | the platform loop | `POST /sessions/nope/outcome` || 404 | session-not-found |

### What an outcome may say

World `policy-default`.

| description | body || status | code |
|---|---||---|---|
| "a logic failure is not an outcome class" | `class: changes-requested` || 400 | outcome-class-unknown |
| "a class outside the vocabulary" | `class: flaky` || 400 | outcome-class-unknown |
| "a missing class" | `{}` || 400 | malformed-body |
| "an unknown key" | `class: no-verdict`, `verdict: APPROVE` || 400 | malformed-body |
| "a credential-shaped evidence value is refused ⚖" | `class: no-verdict`, `evidence: {log: "auth sk-or-v1-FAKE…"}` || 400 | outcome-evidence-refused |
| "evidence over 4096 bytes ⚖" | `class: no-verdict`, `evidence: {log: 5000 × "x"}` || 400 | malformed-body |

### When

| description | sequence || status | result |
|---|---||---|---|
| "an outcome before release is accepted" | report, the session active || 200 | stored |
| "an outcome after release, inside the window ⚖" | DELETE, +3600 s, report || 200 | stored |
| "an outcome after the window" | DELETE, +86401 s, report || 409 | outcome-window-closed |
| "the same outcome twice is a replay ⚖" | report `no-verdict` twice || 200, 200 | one strike; `replay: true` |
| "a different outcome from the same reporter" | report `no-verdict`, then `repetition` || 409 | outcome-conflict |

### What the store holds

| description | sequence || counted strikes on task homelab-2700 | `gateway_strikes_total` |
|---|---||---|---|
| "a model-scoped class strikes the model" | report `no-verdict` || `{opencode, opencode-go/deepseek-v4.1-flash, no-verdict, model, outcome}` | `{class="no-verdict",source="outcome"}` 1 |
| "a serving-scoped class strikes the cell" | report `harness-gave-up` || `{…, harness-gave-up, cell, outcome}` | `{class="harness-gave-up",source="outcome"}` 1 |
| "the gateway writes its own transport class" | the session's request answered `upstream-401` || `{…, auth-storm, cell, gateway}` | `{class="auth-storm",source="gateway"}` 1 |
| "one transport strike per session and class ⚖" | three `upstream-500` answers on one session || one `provider-5xx` | `{class="provider-5xx",source="gateway"}` 1 |
| "a 429 is a cooldown, not a strike ⚖" | the session's request answered `upstream-429` || none | — |
| "a read timeout is a transport strike" | the session's request hit `upstream-slow` (504 `upstream-timeout`) || `{…, timeout, cell, gateway}` | `{class="timeout",source="gateway"}` 1 |
| "an unreachable upstream is a transport strike" | the session's request hit `upstream-down` (502 `upstream-unreachable`) || `{…, provider-5xx, cell, gateway}` | `{class="provider-5xx",source="gateway"}` 1 |
| "a policy refusal is a transport strike, not a rejected credential" | the session's request answered `upstream-403-refused` (403 `upstream-refused`) || `{…, refused, cell, gateway}` | `{class="refused",source="gateway"}` 1 |
| "a cut stream is a transport strike" | `upstream-stream-truncated` on the session || `{…, stream-incomplete, cell, gateway}` | `{class="stream-incomplete",source="gateway"}` 1 |
| "a bare 2xx refutes nothing" | `upstream-500`, then `upstream-ok` on the same session || `provider-5xx` still counted | — |
| "a clean outcome refutes the task's counted strikes" | the session's request answered `upstream-500` (a gateway `provider-5xx`), then the consumer reports `clean` — the ride recovered || none counted; the strike kept, refuted (`refuted: 1`) | — |
| "a clean outcome on another model refutes nothing there" | the heavy tier's `opencode-go/claude-haiku-5-5` struck `no-verdict`; a standard-tier session reports `clean` || the heavy model's `no-verdict` still counted (`refuted: 0`) | — |
| "GET shows the latest outcome" | report `no-verdict` (`subclass: rc=1`), GET || — | `outcome` = `{class: no-verdict, subclass: rc=1, reporter: null}` |
| "the code's vocabulary is the schema's" | `OUTCOME_CLASSES` vs `outcome.input.properties.class` (`enum`, `x-scope`) || equal, class and scope | — |

The provider axis (world `policy-default · openrouter-endpoints`, [GW-RAIL-OPENROUTER](openai-chat.md#gw-rail-openrouter);
a worker session on rail openrouter, `tier: heavy`, rides `deepseek/deepseek-v4.1-flash` pinned):

| description | sequence || strikes on the task (class, provider, refuted) |
|---|---||---|
| "a cell-scoped class lands on the provider the ride rode ⚖" | the ride served by deepinfra; the consumer reports `harness-gave-up` || `[(harness-gave-up, deepinfra, no)]` |
| "a failed-over ride strikes each provider it tried, one per cell ⚖" | deepinfra 500 → atlas-cloud 500 → morph 200 || `[(provider-5xx, deepinfra, no), (provider-5xx, atlas-cloud, no)]` |
| "a clean ride refutes only the cells it rode clean ⚖" | the same, then the consumer reports `clean` || `[(provider-5xx, deepinfra, no), (provider-5xx, atlas-cloud, no)]` — morph served it, the two failed cells stay counted |

### Named gaps

| description | input || v0 answer | the gap |
|---|---||---|---|
| "⚑ gap: the fleet view" | the same class on ≥ 2 distinct tasks || per-task strikes only | the old router's pair cooldown / model nomination across tasks (`router.py:pair_cooldowns`) |

<details markdown="1"><summary>Evidence</summary>

Rendered by `scripts/evidence_render.py` from CI.

--8<-- "GW-SESSIONS-OUTCOME.md"

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
| "a model id is not a credential" | `"model opencode-go/deepseek-v4.1-flash"` || the id verbatim | `<redacted>` |
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
