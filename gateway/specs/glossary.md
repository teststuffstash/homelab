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
may override it. Not the ADR-096 model tier (`cheap`/`large`/`premium`), which is a gap. The
deployed policy's lists are derived from the [tier evidence](#tier-evidence).

## defer

The admission answer "not now": HTTP 200 `{decision: "defer", reason, retry_after_s}` — never
an HTTP error. Typed reasons: `rail-capacity`, `rail-window`, `rail-latched`, `cell-cooled`, `not-in-catalog` (a Go model the [Go catalog](#go-catalog) does not cover), `role-rail-denied`,
`stack-unknown`, `credential-unresolved`, `credential-rejected`, `no-eligible-provider` (the
openrouter model's endpoint snapshot has no provider that clears the policy floors —
[sessions.md §The provider axis](endpoints/sessions.md#the-provider-axis-openrouter)), the
[entry canary](#canary)'s `canary-not-due` and `canary-budget`
([GW-CATALOG-OR](endpoints/catalog.md#gw-catalog-or)), `cells-exhausted` (no
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
[canary](#canary), or `excluded` by a struck one. A model the snapshot does not cover, or none of
whose cells is eligible, rides **unpinned**. Not the [Go catalog](#go-catalog) (the opencode
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

Two policy ids that name ONE model on two rails — the same tail after the rail prefix, a
`:variant` and the vendor are stripped, in the AA spelling (`opencode-go/<id>` ↔ `<vendor>/<id>`;
`tiers.same_model`, one rule, no table). When a tier's lists name a twin on two of the role's
allowed rails, admission runs the **rail choice** ([GW-MODEL-TIERS §The rail choice](endpoints/catalog.md#the-rail-choice)):
the rail whose twin cell costs less per clean ride walks first, with that twin at its list's
head; the role's rail order stands for everything else. A `claude/` alias names a family, never a
model: it twins nothing.

## canary

Narrowed here to the **entry canary** ([GW-CATALOG-OR §The entry canary](endpoints/catalog.md#the-entry-canary)):
one ride through this gateway on exactly one `(model, provider)` [cell](#cell) of the openrouter
rail — a session admitted with `canary: {model, provider}` (the policy's `canary.role` and
`canary.harness`), pinned with fallbacks off and no failover — whose outcome is the cell's verdict:
`clean` → `eligible`, a strike → `excluded`. It is the catalog's own gate, on demand (as the
catalog refreshes) and budget-capped (`canary.max_per_refresh`, `canary.usd_per_day`). The
platform's unqualified **canary** ([`docs/glossary.md`](../../docs/glossary.md)) is the scout's
rail probe of a (model, harness, class) cell; this one adds the provider axis and supersedes the
scout's canary leg for OpenRouter entrants.

## persistence interface

The `Store` seam the codex OAuth lifecycle runs behind — `lock()` / `load()` / `save()`, one
account per store, the lock held across load → refresh → save, `save` atomic and durable
([GW-CODEX-OAUTH](endpoints/openai-responses.md#gw-codex-oauth)). Only a FAKE (process-memory)
implementation exists; the production one is a `⚑ gap`.

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
