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

A billing/credential lane upstream. v0 has four; each has one upstream host, one
credential source and one `max_sessions` cap in the policy.

| rail | credential | upstream host | dialects served |
|---|---|---|---|
| `anthropic` | the operator's Claude subscription OAuth token (`AUTH_TOKEN` in the stack's `claude-session` Secret) | `api.anthropic.com` | anthropic |
| `opencode` | the OpenCode Go subscription key (the gateway's own mounted Secret) | `opencode.ai/zen/go` | anthropic, openai |
| `openrouter` | the per-stack OpenRouter key minted by openrouter-operator | `openrouter.ai/api/v1` | anthropic, openai |
| `codex` (lit 2026-10-22) | the operator's ChatGPT subscription OAuth record (the gateway's own login), behind the persistence interface — gateway-local SQLite seeded from an ESO-mounted file, no write-back ([GW-CODEX-OAUTH](endpoints/openai-responses.md#gw-codex-oauth)) | `chatgpt.com/backend-api/codex` (the deployed `CODEX_UPSTREAM`; no code default) | responses |

Out of v0 and named only as gaps: `zen`.

## dialect

The wire format of an LLM request — which inbound path the pod speaks and which upstream
endpoint shape it maps to. `anthropic` = Anthropic Messages (`/anthropic/v1/messages`);
`openai` = OpenAI Chat Completions (`/openai/v1/chat/completions`, plus `GET /openai/v1/models`);
`responses` = OpenAI Responses over SSE (`/openai/v1/responses` — streaming, `store: false`).
A harness speaks exactly one dialect; a rail serves one or both (table under *rail*).

## harness

The agent CLI the pod runs: `claude`, `opencode`, `goose`, `codex` (its rail lit 2026-10-22). The
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
harness's side-calls may name on any session of that rail), per-model `context_tokens` (the
non-Go rails only — a Go model's window is the Go catalog's `context`, ruling 5), `session_ttl_s`.
**No model id lives in code** — only here, copied from
`argocd/resources/openrouter-proxy/model-classes.json`; the deployed policy
(`argocd/resources/agent-gateway/policy.json`, the source of the `agent-gateway-policy`
configMapGenerator) has the same shape and is loaded by a
test row.

## tier

A size label on a session — `light` | `standard` | `heavy` — that selects the model within the
chosen rail: `rails.<rail>.models.<tier>`, an ORDERED list the walk takes the first admissible
model of (not struck by this task, not cooled; a bare string = a one-item list —
[§The retry contract](endpoints/sessions.md#the-retry-contract--model-lists-strikes-attempt)). The role's default comes from the policy; the caller
may override it, and may ask for the list to be walked from its END (`prefer: strongest` —
[§The preferred end of the list](endpoints/sessions.md#the-preferred-end-of-the-list)). Not the ADR-096 model tier (`cheap`/`large`/`premium`), which is a gap. The
deployed policy's lists are derived from the [tier evidence](#tier-evidence).

## defer

The admission answer "not now": HTTP 200 `{decision: "defer", reason, retry_after_s}` — never
an HTTP error. Typed reasons: `rail-capacity`, `rail-window`, `rail-latched`, `cell-cooled`, `not-in-catalog` (a Go model the [Go catalog](#go-catalog) does not cover), `role-rail-denied`,
`stack-unknown`, `credential-unresolved`, `credential-rejected`, `no-eligible-provider` (the
openrouter model's endpoint snapshot has no provider that clears the policy floors —
[sessions.md §The provider axis](endpoints/sessions.md#the-provider-axis-openrouter)), the
[entry canary](#canary)'s `canary-not-due` and `canary-budget`
([GW-CATALOG-OR-CANARY](endpoints/catalog.md#gw-catalog-or-canary)), `cells-exhausted` (no
`retry_after_s`: every cell is struck for this task — escalate, do not poll), and the codex rail's headroom verdicts `quota-unknown`,
`quota-stale`, `quota-limited` ([GW-CODEX-HEADROOM](endpoints/openai-responses.md#gw-codex-headroom)).
The caller polls after `retry_after_s` — for a capacity-blocked rail, the moment the block lifts
([sessions.md §Capacity](endpoints/sessions.md#capacity--the-ladders-capacity-half)).

## cell

A (rail, model, **provider**) triple — one model served on one rail by one provider, the unit a
429 cools, a strike excludes and an outcome judges
([sessions.md §Capacity](endpoints/sessions.md#capacity--the-ladders-capacity-half),
[§The provider axis](endpoints/sessions.md#the-provider-axis-openrouter)). The provider is the
endpoint tag's base slug on the openrouter rail — what `provider.order` names, joined from the
answer's display name through the [endpoint snapshot](#endpoint-snapshot)
([openai-chat.md §Attribution](endpoints/openai-chat.md#attribution--the-answer-names-the-cell)) —
and `''` on the rails that pin none, or when no answer named one. The old router's cell was
(model, provider) with a price and a pin ([model-routing.md](../../docs/agents/model-routing.md));
the gateway's carries the rail and keeps the price in the snapshot.

## endpoint snapshot

The openrouter rail's registry: per model, the rows of `GET /api/v1/models/<id>/endpoints`
(provider slug and display name, quantization, tool-choice support per mode, `uptime_last_1d`,
latency, prices) as the gateway last read them, kept in its store under
`catalog_snapshots.openrouter-endpoints`
(`openai-chat.schema.json` `$defs.endpoint_snapshot`). [Selection](endpoints/openai-chat.md#selection--the-gateways-own-evidence-never-exacto)
reads it; [GW-CATALOG-OR](endpoints/catalog.md#gw-catalog-or) writes it (the vendor's weekly
ranking ∩ the AA-benched set, then each candidate's endpoints) and keeps, beside it, each
`(model, provider)` cell's **entry state** — `candidate` → `eligible` by one clean
[canary](#canary), or `excluded` by a struck one — and, on the view (`GET /catalog/openrouter`),
whether the cell is **pinnable** per harness: the floors' verdict, the data plane's own predicate,
so that an `eligible` cell selection could never pin is visible BEFORE a canary is spent on it
(the launcher walks only pinnable candidates, cheapest first). A model the snapshot does not cover,
or none of whose cells is eligible, rides **unpinned**. Not the [Go catalog](#go-catalog) (the opencode
rail's vendor facts) and not the [tier evidence](#tier-evidence) (the benchmark snapshot the tier
lists derive from).

## headroom

The codex rail's account capacity as the gateway last saw it: one normalised snapshot of the
subscription's windows (used fraction, reset time) plus an explicit `limited` flag, replaced only
by a strictly newer valid report. Its verdict (`admit`, `quota-unknown`, `quota-stale`,
`quota-limited`) gates admission onto the rail
([GW-CODEX-HEADROOM](endpoints/openai-responses.md#gw-codex-headroom)); Prometheus observes it,
never decides it.

## Go catalog

The opencode rail's vendor facts as the gateway last read them: two **snapshots**, one per
source — `config` (models.dev's `opencode-go` catalog with the console's V2 config as the
workspace's overlay — listed models, cost tiers, context/output limits, tool support) and `docs` (the vendor's Go page: each model's monthly limit per **plan**, promotion
multipliers, peak rows and hours, the 5h/weekly/monthly shares). Refreshed on a schedule; a failed,
unparseable or implausible refresh keeps the last good snapshot, which the store persists
([GW-CATALOG-GO](endpoints/catalog.md#gw-catalog-go)). *Listed* means in the config snapshot — the merged
listing, models.dev's rows under the workspace's **overrides** (the console's overlay) — an account
fact, not a liveness signal. **Plan** = `go` | `go-plus`, declared in the policy
(`rails.opencode.plan`) because no vendor API says which one a key is on.

## tier evidence

The benchmark rows the DEPLOYED policy's [tier](#tier) lists are derived from
([GW-MODEL-TIERS](endpoints/catalog.md#gw-model-tiers)): a committed snapshot
(`argocd/resources/agent-gateway/benchmarks.json`) of every candidate policy id per rail with its
Artificial Analysis row (joined by rule, never a table), its price (the openrouter model's
SELECTED endpoint's; the [Go price](#go-price)), its clean-ride evidence and its Go monthly
limit, plus the policy's `tiers` block — the score axis, the per-tier **score bands** as
fractions of the rail's top score, the cap, the `cost` terms. The lists are the derivation's output, each ordered by [cost per clean ride](#cost-per-clean-ride);
a hand edit fails the suite. A tier with no priced candidate (the openrouter rail before its first
eligible cell) is **undecided**: its deployed list stands, `apply` refuses to write it.
*Score band* here is the `tiers.bands` fraction, not the ADR-104 curation band of
[`docs/glossary.md`](../../docs/glossary.md) (`regular` / `premium` / `ultra` / `instrument`).
A **manual benchmark row** (`benchmarks-manual.json`) is a hand-entered score for an id the feed
does not carry yet — it scores only until the feed has the id, then it is retired.
Refreshed by hand (`scripts/benchmarks-snapshot.sh`), its age a gauge the `TierEvidenceStale`
alert reads; the fixture worlds carry the block but keep their fixture lists.

## cost per clean ride

The one number a [cell](#cell) is ordered and chosen by ([GW-MODEL-TIERS §Cost per clean ride](endpoints/catalog.md#cost-per-clean-ride)):
what one ride that ENDS CLEAN costs, counting the rides that did not — the cell's price for a
ride's output tokens over its **clean-ride rate**, plus the strike overhead on every failed ride
in between. The price is the cell's own: on the openrouter rail the SELECTED endpoint's (never
the headline), on the Go rail the plan's fee over what the plan bought ([Go price](#go-price)).
The clean-ride rate is measured from the outcome store once the cell has `tiers.cost.min_rides`
judged rides, a prior before (the selected endpoint's uptime; 1.0 on the Go rail). The terms are
the policy's `tiers.cost`. Operator ruling 2026-10-19 (homelab#2718): per-token prices are not
the tier order.

## Go price

The opencode rail's price per model, derived rather than listed: the model's list price × the
plan's **discount** = `fee ÷ max(the rail's trailing-30-day list-priced draw, the model's monthly
limit)` — the fee buys at least the model's own allowance (`promise`), and a busier rail makes
every Go token cheaper (`measured`); an unlimited model prices at 0. The fee is the Go page's
Plan table ([Go catalog](#go-catalog)), the draw the gateway's own ledger at the catalog's list
rates (the same arithmetic as the window draw). Shown on `GET /catalog/opencode` `pricing`
([GW-MODEL-TIERS](endpoints/catalog.md#gw-model-tiers)).

## twin

Two policy ids that name ONE model on two rails — the same tail once the rail prefix, a
`:variant` and the vendor are stripped, in the AA spelling (`opencode-go/<id>` ↔ `<vendor>/<id>`;
`tiers.same_model`, one rule, no table). When a tier's lists name a twin on two of the role's
allowed rails, admission runs the **rail choice** ([GW-RAIL-CHOICE](endpoints/catalog.md#gw-rail-choice)):
the rail whose twin cell costs less per clean ride walks first, with that twin at its list's
head; the role's rail order stands for everything else. A `claude/` alias names a family, never a
model: it twins nothing.

## canary

Narrowed here to the **entry canary** ([GW-CATALOG-OR-CANARY](endpoints/catalog.md#gw-catalog-or-canary)):
one ride through this gateway on exactly one `(model, provider)` [cell](#cell) of the openrouter
rail — a session admitted with `canary: {model, provider}` (the policy's `canary.role` and
`canary.harness`), pinned with fallbacks off and no failover — whose outcome is the cell's verdict:
`clean` → `eligible`, a strike → `excluded`. It is the catalog's own gate, on demand (as the
catalog refreshes) and budget-capped (`canary.max_per_refresh`, `canary.usd_per_day`). The
platform's unqualified **canary** ([`docs/glossary.md`](../../docs/glossary.md)) was first the
model scout's rail probe of a (model, harness, class) cell; this one adds the provider axis, and since
the scout's retirement (2026-11-01) it is the platform's only canary.

## headroom report

One observation of the codex account's capacity in the gateway's own schema
(`openai-responses.schema.json` `headroom.report`): `observed_at`, `source`, `limited` and the
profile's `windows` (`used_percent`, `resets_at`, `window_minutes`) — never a vendor payload. Two
producers write one, both the gateway's own: the usage poll
([GW-CODEX-USAGE-POLL](endpoints/openai-responses.md#gw-codex-usage-poll), `source: poll`) and the
relayed answer's `x-codex-*` headers
([GW-CODEX-UPSTREAM-HEADERS](endpoints/openai-responses.md#gw-codex-upstream-headers),
`source: upstream`). A report replaces the [headroom](#headroom) snapshot only when it is valid and
strictly newer; a refused report leaves the last accepted one standing.

## turn state

The value of the one routing header the codex rail round-trips, `x-codex-turn-state`: issued by
the backend on a successful stream, recorded by the gateway bound to the authenticated session, the
gateway-owned account and the pinned client's `client_metadata.turn_id`, and accepted back only as
that exact value within that turn ([GW-RAIL-CODEX §Opaque turn state](endpoints/openai-responses.md#opaque-turn-state)).
A new turn clears it; a replay of any other value is 400 `turn-state-invalid` before any inference
call. Not durable, bounded (4096 bytes), never a credential.

## capture bundle

The sanitized record of one scoped codex session at its four boundaries — client request received,
upstream request sent, upstream response received (status, headers, then every relayed SSE event),
client response sent — read back as one document by `GET /sessions/{id}/capture`
([GW-CODEX-CAPTURE](endpoints/openai-responses.md#gw-codex-capture)): header values withheld but for
an allowlist, strings as lengths, identifiers as run-local aliases, `complete: false` when the byte
bound cut a request. Pulled into restricted storage and reviewed before any excerpt becomes a spike
paragraph or a fixture.

## persistence interface

The `Store` seam the codex OAuth lifecycle runs behind — `lock()` / `load()` / `save()`, one
account per store, the lock held across load → refresh → save, `save` atomic and durable
([GW-CODEX-OAUTH](endpoints/openai-responses.md#gw-codex-oauth)). Tests drive a FAKE (process-memory)
implementation; production runs gateway-local SQLite in `GATEWAY_DB` (`sqlite_oauth.py`).

## control plane / data plane

Control plane = `/sessions` (admission, lookup, release, the [judge](#judge)'s list by task), `/healthz`, `/metrics`, `/catalog/opencode`. Data plane =
the two dialect paths the pod's LLM traffic rides. `/sessions` is called by launchers with their
projected ServiceAccount token, checked against the policy's `callers`
([GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth); `/healthz`, `/metrics` and `/catalog/opencode` stay open,
in-cluster only); the data plane requires a session token.

## judge

A control-plane caller whose `callers` entry says **`outcome: any`**: it may report an outcome on
any [session](#session) of its stacks, not only the ones it admitted, and `GET /sessions?task=`
shows it every session of its stacks carrying that task
([sessions.md §Who may report](endpoints/sessions.md#who-may-report), [§A judge finds a task's
sessions](endpoints/sessions.md#a-judge-finds-a-tasks-sessions)). It exists because a reviewer
cannot grade its own verdict: `wrong-verdict` is a judge's class only, written after a later check
— the deployed judge is the deploy-revert chain's judge step, which reports it on the review
sessions of a merge the chain reverted (FU-270 (b)). A judge admits nothing (roles `[]`, no bind);
the key is optional and `own` by default, so an absent key grants nothing extra.

## world

A named fixture state a row runs against: a policy document plus a fake-upstream behaviour
([worlds/README.md](worlds/README.md)). Row ids carry the world when a requirement's evidence
spans more than one.

## store mode

Which store the gateway opened at start, reported as `db` by [`GET /healthz`](endpoints/health.md)
([GW-HEALTH](endpoints/health.md#gw-health)): `pvc` = SQLite at `GATEWAY_DB` (`/data/gateway.db`
on the Longhorn PVC) — sessions survive a restart; `memory` = the **fail-open** in-memory store the
gateway falls back to when that path is missing, read-only or corrupt at start — it keeps admitting,
logs one `ERROR` line, and forgets every session at the next restart. Chosen once per process; it is
the `gateway_db_mode` gauge on `/metrics` ([GW-METRICS](endpoints/metrics.md#the-store-mode-is-a-gauge)),
which `GatewayStoreMemoryMode` reads.

## bounded label

A Prometheus label whose value set `metrics.schema.json` declares in full
([GW-METRICS](endpoints/metrics.md#gw-metrics)): a value outside the set renders as `other`, so a
task key, a session id, a token or a model the policy does not name can never create a series —
cardinality is a property of the policy, not of traffic. `model` is bounded to the policy's
openrouter ids and `provider` to the endpoint snapshot's slugs; `task`, `session`, `id` and `token`
are no label on any family.

## access inventory

The role × stack × service table of [access.md](access.md) (operator ruling 2026-10-15): rows are
roles, columns are services (the three rails, git identity, stack MCP, browser MCP), cells are what
the launcher does today. The gateway enforces only the rail columns, per `roles.<role>.rails`
([GW-ACCESS](access.md#gw-access)); the control-plane caller is enforced per ServiceAccount
([GW-SESSIONS-AUTH](endpoints/sessions.md#gw-sessions-auth)); every other column is documented
reality, unenforced.

## wire id

The `model` the upstream receives: the [policy](#policy) id with its [rail](#rail) prefix
removed — `opencode-go/x` → `x` on the Go rail; an openrouter id is already bare; on the
anthropic rail the body's own spelling, untouched (the policy names a `claude/<alias>` family the
claude CLI resolves itself) — [GW-MODEL-RESOLVE](endpoints/anthropic-messages.md#gw-model-resolve).
An absent body `model` is filled with it. Not the policy id (what a [session](#session) pins and
the dispatch answer names) and not a [twin](#twin) (two policy ids, one model).

## pin

The provider the gateway names for ONE attempt on the openrouter rail: `provider: {order: [slug],
allow_fallbacks: false}` on the upstream body, the harness's other keys unchanged
([GW-RAIL-OPENROUTER §Selection](endpoints/openai-chat.md#selection--the-gateways-own-evidence-never-exacto)).
The slug is the first [cell](#cell) of the order the [endpoint snapshot](#endpoint-snapshot) and
the clean-ride evidence give; a failed pinned attempt moves to the next before any byte is relayed
([§Failover](endpoints/openai-chat.md#failover--before-the-first-byte-only)). A model the snapshot
does not cover, or a session whose eligible cells are all struck or cooled mid-ride, rides
**unpinned** — no `provider` block, the vendor's own routing. The answer's own provider name
outranks the pin for attribution. Not the `:exacto` suffix (never ported) and not a session's
model pin (a session pins a model for its life — [session](#session)).
## walk

The admission's one pass over a role's rails, in the policy's order, cell by cell: for each rail
not held by its [capacity](endpoints/sessions.md#gw-sessions-capacity) the [tier](#tier)'s ordered
model list is read and the first [cell](#cell) the task has not [struck](#strike), that is not
[cooled](#cooldown), and whose credential resolves is taken — its dialect names the harness
([GW-SESSIONS-ADMIT](endpoints/sessions.md#gw-sessions-admit)). The walk ends in a `dispatch` on
that cell or a [`defer`](#defer) naming the rail that frees first; only when strikes alone hold every
cell is the answer `cells-exhausted` ([GW-SESSIONS-RETRY](endpoints/sessions.md#gw-sessions-retry)).

## strike

A row of the outcome store keyed `(stack, task, rail, model, provider, harness)` with a class, a
**scope** and a **source**: `outcome` when the consumer reported how its ride ended, `gateway` when
the gateway saw the transport fact itself ([GW-SESSIONS-OUTCOME](endpoints/sessions.md#gw-sessions-outcome)).
Scope says what the next [walk](#walk) excludes for the task: a cell-scoped strike the
[cell](#cell), a model-scoped one the policy id on every rail, a harness-scoped one every cell the
struck harness would ride. A strike is **counted** until a `clean` outcome on the same cell, model
or harness refutes it (it stays as history with `refuted_at` set); a bare 2xx refutes nothing. Not a
round: a logic failure is the consumer's round counter's, never a class here.

## cooldown

A [cell](#cell) held after an upstream 429 until the reset the wire named — `retry-after`, then
`x-ratelimit-reset`, else the rail's `latch_429_hold_s`, else `defer_retry_s`; any 2xx on the cell
clears it early. Admission skips a cooled cell (`cell-cooled`, `retry_after_s` = its reset) and
takes the tier list's next model; a 429 writes no [strike](#strike)
([GW-SESSIONS-CAPACITY](endpoints/sessions.md#gw-sessions-capacity)).

## latch

A whole [rail](#rail) held after an upstream 429, because the policy declares the rail one account
whose limits are account windows (`latch_scope: account` — the anthropic subscription, the Go rail
since 2026-11-01): the 429 cools its cell AND latches the rail for the same reset, or the rail's
`latch_429_hold_s` when none was named; any 2xx on the rail clears it. A rail that declares no latch
(openrouter) is never latched — its 429s are per-model facts, a [cooldown](#cooldown) each
([GW-SESSIONS-CAPACITY](endpoints/sessions.md#gw-sessions-capacity)).

## capacity mark

What the gateway's capacity state remembers between admissions, one row of the store's
`capacity_marks` table each: `cooled` (a cell's [cooldown](#cooldown) and its `until`), `latched` (a
rail's [latch](#latch)), `rejected` (a credential's rail + sha256 fingerprint, its stack, the
backoff and the next re-verification) and `hold` (the backoff a credential's next rejection doubles
from) — never a credential value. A new gateway on the same DB reloads them at start, dropping only
what the in-memory logic would already have let go
([GW-SESSIONS-CAPACITY §Kept across a restart](endpoints/sessions.md#kept-across-a-restart)).

## wire source

One vendor read the gateway makes, named (`go-models-dev`, `codex-usage`, …) and classed `public`
(the read sent no credential and no account header — its bytes are kept verbatim) or `account`
(anything else — kept as structure with every string reduced to its length). Each source has one
[wire record](#wire-record)
([GW-WIRE-RECORD](endpoints/wire.md#gw-wire-record)).

## wire record

The latest answer of a [wire source](#wire-source) as the gateway's store keeps it — the stored bytes, their provenance
(class, url, status, bytes, sha256, fetched_at, complete) and the latest failed read beside it — recorded before the
parser reads the answer, replaced by the next good one, served read-only at `GET /wire/<source>`
([GW-WIRE-VIEW](endpoints/wire.md#gw-wire-view)).
