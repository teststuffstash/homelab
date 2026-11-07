---
id: IF-BUDGET
use-cases: [UC-1]
schema: budget.schema.json
---
# `estimate_budget.py` — size the per-session cap before the ride

*How much may this ride spend before it is cut off?* A coarse sizing tool, not a predictor: the
per-session key's cap is the circuit breaker (the upstream refuses past it), so the estimate only
has to land in the right tier, and over-sizing beats throttling a legitimate fix — an unspent cap
costs nothing ([`agents/estimate_budget.py`](../../../estimate_budget.py) docstring). Consumers:
the coordinator brief (prices a model, emits the session key's CR before a dispatch), `retro-session.sh`
and `research-fanout.sh` (their own keys), and `goal-budget.sh`'s `gb_cap` (the reservation unit of
[LAUNCH-PREFLIGHT-GOAL-BUDGET](dispatch.md#launch-preflight-goal-budget)).

## Interface — the machine half

| requirement | schema path | exit codes |
|---|---|---|
| [LAUNCH-BUDGET-ESTIMATE](#launch-budget-estimate) | `cli`, `estimate` | 0 · 2 (argparse) |
| [LAUNCH-BUDGET-CR](#launch-budget-cr) | `cr` | 0 |

## Requirement index

| Requirement | section | Status |
|---|---|---|
| [LAUNCH-BUDGET-ESTIMATE](#launch-budget-estimate) | the estimate | 🚧 WIP — no evidence pipeline yet; no fixture (`--self-test` guards the pure core — unit-level, unlabelled, so no evidence by CONVENTIONS § Allure taxonomy; `goal-budget-gate` drives it only through `gb_cap`) |
| [LAUNCH-BUDGET-CR](#launch-budget-cr) | the key | ⚑ gap: a gateway ride holds no key — the gateway holds the rail's credential, and the per-session cap has no redrawn home yet |

## The estimate

### LAUNCH-BUDGET-ESTIMATE

`cost ≈ rounds × requests_per_round × context_tokens × price_per_mtok × (1 − cache_hit) / 1e6`
(:180–193). `requests_per_round` is banded by the issue's size in tokens (characters / 4): < 500 →
50, < 2000 → 90, else 160. ⚖ `context_tokens` defaults to **50 000** (the context re-sent per
request, sized from measured worker transcripts with their cache reads priced in — retro r8 F4) and
`rounds` to 3; ⚖ `cache_hit` defaults to **0** for an override or static price (size for the worst
case). The tier is the smallest whose selection ceiling holds `estimate × BUFFER` (⚖ **2.0**),
minted at that tier's enforced cap: `xs` ≤ 0.25 → $0.50, `sm` ≤ 0.50 → $1.00, `md` ≤ 1.00 → $2.00,
`lg` ≤ 2.00 → $4.00; past the top ceiling the cap stays $4.00 and `escalate` is true — a human looks
before that much is spent. An `agent-budget/<tier>` label forces the tier (never escalates); an
unknown tier is an error. The price comes from `--price-per-mtok`, else the 24 h registry cache of
OpenRouter's `/models` + `/endpoints` (cache-aware effective input price), else the static table,
else $1.0/M; each table is tried for the id as given, then its base id (a provider-routing suffix
stripped, `model_id.py`). The JSON answer on stdout carries the estimate's fields plus
`price_source` and `price_note`; the price line goes to stderr.

> **External:** verify during implementation — OpenRouter's `/api/v1/models/<id>/endpoints` pricing fields (`prompt`, `input_cache_read`) and `uptime_last_1d` (read into the registry cache; the probe table lives in [docs/agents/model-routing.md §The OpenRouter API surface](../../../../docs/agents/model-routing.md#the-openrouter-api-surface-probed--the-one-reference)).

**World:** `launcher-vars` — `--price-per-mtok` fixes the price, `--issue-chars` the size, no
registry.

#### Estimate and tier

Legend: `issue_chars` / `price` = the inputs; `rpr?` = requests per round; `estimate?` = USD;
`tier?` / `cap?` / `escalate?` = the pick. `rounds` 3 and `context_tokens` 50 000 throughout.

| description | world | issue_chars | price | cache_hit | label | rpr? | estimate? | tier? | cap? | escalate? |
|---|---|---|---|---|---|---|---|---|---|---|
| a one-liner on a cheap model | launcher-vars | 400 | 0.01 | 0 | — | 50 | 0.075 | xs | 0.50 | false |
| a one-liner at $0.02/M | launcher-vars | 400 | 0.02 | 0 | — | 50 | 0.15 | sm | 1.00 | false |
| a one-liner at the static deepseek price ⚖ | launcher-vars | 400 | 0.10 | 0 | — | 50 | 0.75 | lg | 4.00 | false |
| a normal fix past the top ceiling | launcher-vars | 4000 | 0.10 | 0 | — | 90 | 1.35 | lg | 4.00 | true |
| a multi-file change on an unknown model | launcher-vars | 12000 | 1.0 | 0 | — | 160 | 24.0 | lg | 4.00 | true |
| a label forces the tier | launcher-vars | 400 | 0.10 | 0 | `agent-budget/sm` | 50 | 0.75 | sm | 1.00 | false |
| a measured cache hit ⚖ | launcher-vars | 400 | 0.10 | 0.9 | — | 50 | 0.075 | xs | 0.50 | false |

_Evidence: none yet — unverified._

## The key

### LAUNCH-BUDGET-CR

`--emit-cr --project P --session S` prints an ephemeral `OpenRouterKey` (openrouter-operator) sized
to the estimate: `metadata.name` = `P-S` (lowercased, `_` → `-`), namespace P, labels `budget-tier`
and `budget-estimate-usd` (the ledger's calibration reads them); `spec.budgetUSD` = the cap,
`ephemeral: true`, `session: S`, `secretName: P-session-S-openrouter` — set explicitly so the
dispatcher passes that exact name to `--openrouter-secret` and never reconstructs it — and
`expiresAt` = now + `--ttl-hours` (default 4, matching the pod's deadline) (:617–647). An escalated
estimate is said on stderr before the CR, so an emit-cr caller does not apply it blind.

⚑ gap — this is old contract on the OpenRouter rail only. A gateway ride holds no key: the gateway
resolves the stack's credential ref itself
([GW-CRED-RESOLVE](../../../../gateway/specs/endpoints/sessions.md#gw-cred-resolve)) and the
launcher's `--openrouter-secret` is stripped on a re-admission. The redrawn contract has no
per-session spend cap yet: the gateway answers `context_tokens` (a window, not a budget), and the
supplier's own catalog tracks cost per clean ride, not a per-session ceiling (unverified — expected:
the cap moves to wherever the credential lives, i.e. the gateway, as an admission input). Until then
the goal-budget gate keeps reserving `cap_usd` for gateway rides, which spend no OpenRouter key on
the subscription and Go rails (the `subscription-ride-*` rows of
[LAUNCH-PREFLIGHT-GOAL-BUDGET](dispatch.md#launch-preflight-goal-budget) price those at $0).

**World:** `launcher-vars`, `--issue-chars 400 --price-per-mtok 0.10 --project homelab --session
issue-42-round-1`.

| description | world | project | session | name? | secret_name? | budget_usd? | tier_label? |
|---|---|---|---|---|---|---|---|
| a session key for one round | launcher-vars | homelab | issue-42-round-1 | homelab-issue-42-round-1 | homelab-session-issue-42-round-1-openrouter | 4.0 | lg |

_Evidence: none yet — unverified._
