# Model routing — chains, strikes, and a live registry (not one hardcoded model)

**This doc owns model choice** — failure taxonomy, fallback chains, the live registry, provider
pinning, attribution, the scout, and the task-class pilots. Born from the oracle-fleet issue #1
postmortem and the 2026-06-29 qwen cost autopsy (both in [`docs/spikes/model-routing-history.md`](../spikes/model-routing-history.md) §"The problem, from evidence").

**Where the machinery lives:** the registry is `estimate_budget.py` (cached `/models` +
`/endpoints`, cache-aware effective price, `--lookup`); strike bookkeeping is `AGENT_STRIKE`
comments from the launcher; provider injection and the router/budgeter are the egress proxy
(ADR-087, ADR-096). Companions: [`observability-and-retro.md`](observability-and-retro.md) (the
ledger this feeds) and
[`../../agents/coordinator/README.md`](../../agents/coordinator/README.md) (the brief that
executes it).

For the design journey that led to these rules, see [`../spikes/model-routing-history.md`](../spikes/model-routing-history.md).

## The OpenRouter API surface (probed — the one reference)

Consolidated 2026-08-03 (this kept living in operator conversations; the probes are scattered
through ADR-096's addenda, which stay the decision record — THIS list is the lookup table).
Upstream reference: <https://openrouter.ai/docs/api_reference/overview>. Auth = `Authorization:
Bearer <key>` everywhere; "probed" = verified against our account, with date.

| surface | what it gives us | gotchas (probed) |
|---|---|---|
| `POST /api/v1/chat/completions` | the data plane (proxy-fronted, ADR-081/087) | `provider.order` matches **tag slugs**; omitted `provider` = 1/price² lottery (the $5.79 lesson) |
| `GET /api/v1/models` | catalog + headline prices (the registry cache) | `order=top-weekly` is **ignored** — no rankings REST API exists (2026-08-02) |
| `GET /api/v1/models/:author/:slug/endpoints` | per-provider price/uptime (effective-price basis) | `uptime_last_5m/_1d` is OpenRouter's routing view — **blind to per-account limits** (laguna: "100% up" while we saw 81% 429) |
| `GET /api/v1/auth/key` | live headroom: `limit`, `limit_reset: weekly` (2026-07-27) | — |
| `GET /api/v1/credits` | account balance | **management-key only** — a project-scoped key (and so every in-cluster caller we have) gets `403 "Only management keys can fetch credits for an account"`. Nothing calls it: the balance reaches us via the openrouter-operator's `openrouter_account_credit_usd` gauge → the proxy's capacity latch → `GET /router-status` (homelab#180/#190) |
| `GET /api/v1/generation?id=` | billed `total_cost` + native tokens + provider per request | same session key works; feeds `router_observed_cache_hit` |
| `GET /api/v1/activity` | account-wide usage | **management-key only** — not worth holding one in-cluster (FU-095 backfill idea parked) |
| frontend `/api/frontend/v1/benchmarks` | model quality scores | **session-cookie-gated, API key 401s** (2026-08-02) — see MCP row |
| MCP `https://mcp.openrouter.ai/mcp` | `list-daily-model-rankings` (rotation feed, top-30 daily, live since 2026-07-27), `list-models`/`get-model`, `search-docs`, **`list-benchmarks`**, **`list-task-classifications`**, `get-endpoint-uptime-history`, `list-presets`/`get-preset` | standard API key works for rankings (no OAuth dance, 2026-08-02); full tool set via OAuth (7-day key, $10 cap, includes BILLABLE `send-message`). Probed 2026-08-03 (OAuth): `list-benchmarks` sources = `artificial-analysis` (AA intelligence/coding/agentic composite indices, ~126 models) **and `openrouter` — OpenRouter's OWN evals (gpqa_diamond accuracy + $/task), i.e. the formerly session-gated frontend data**; `list-task-classifications` = 7d traffic share per task tag (incl. `code:devops_config`, `devops`, `security_audit`, `research_report`) with top-10 models each; `get-endpoint-uptime-history` = 72h hourly per-provider uptime **with quantization in the endpoint label** (fp8/fp4 — the §M4 staleness/quant filter's data). **Probed 2026-08-03: the standard account key pulls `list-benchmarks` AND `list-task-classifications`** (jail replay of the proxy's exact `_mcp_call` shape with the `router-account-key` Secret) — the scout's weekly capability/market pull is fully automatable server-side; OAuth is only needed for the interactive/billable tools |
| provisioning keys API | mint per-run capped keys (the ADR-081 runtime-key design) | scout canary keys ride this with `only-free` guardrail (FU-024) |
| frontend `/api/frontend/v1/stats/effective-pricing?permaslug=` | per-provider 30d market effective prices + REAL cache-hit (the §M3 market basis) | works **unauthenticated** (2026-08-26). ⚠ takes the **DATED permaslug** (`deepseek-v4-flash-20260731`), never the model id (`…-0731`) — the wrong form returns an EMPTY payload, not an error. The proxy already derives it from `/endpoints` tag names (`_PERMASLUG_RE`); a hand probe must too. Ranks effective **input** price only — output price and quality are not in it |
| frontend `/api/frontend/v1/stats/tool-call-error-rate?permaslug=` | per-ENDPOINT daily tool-call error-rate series (the Performance-tab modal's data — the Auto Exacto quality signal itself) | found 2026-08-26 after the RSC row below couldn't reach it (the tab lazy-loads); unauthenticated; endpoint ids join to providers via `endpointStats`/`/endpoints`. THE §M14 pin-v2 live-floor input + a fleet alerting feed (a provider at 39.6% tool-error read 99.6% *uptime* — "up" ≠ "works") |
| model-page RSC stream (`GET openrouter.ai/<author>/<slug>` + `RSC: 1` header) | the Performance-tab data as React-Query dehydrated state, keyed by dated permaslug: **`benchmarkScores`** (per-provider Auto-Exacto benchmark rows — gpqa_diamond + TAU-Bench score, `run_count`, `endpoint_id`, 32d rolling — the quality table behind Exacto routing), **`endpointStats`** (per-provider latency/throughput **percentiles** p50–p99, `is_deranked`, `capacity_tpm`, quantization — richer than `/endpoints`), **`appStats`** (daily model-level `total_tool_calls` + `requests_with_tool_call_errors` → the model-wide tool-call error rate), `uptimeRecent`, `topColos` | probed 2026-08-26 (the 0731 read). Unauthenticated. ⚠ the PER-PROVIDER **Tool Call / Structured Output Error Rate** table lazy-loads on tab open and is NOT in the initial stream — its endpoint is unfound (candidate paths under `/api/frontend/v1/stats/*` all 404); the website is the only reader today. The signal is still CONSUMABLE blind: **Auto Exacto** reorders providers by it on every tool-calling request by default, and the **`:exacto`** model-variant suffix applies it explicitly — ⚠ an explicit §M4 `provider.order` pin presumably suppresses it (unverified; the 0731 matrix run tests this) |

Roster additions probed 2026-08-26 on the MCP row (standard `router-account-key`, no OAuth):
`get-credits` **works with the standard account key** — the REST `/api/v1/credits` row above is
management-key-only and grew the #180/#190 operator-gauge detour; the MCP tool may be the simpler
leg if that chain ever needs rework (noted, not acted on). Also new: `list-providers`,
`list-app-rankings`, `list-model-endpoints` (byte-identical field set to `/endpoints` — no error
rates), `send-feedback` (per-generation feedback), `get-generation`, media tools
(`generate-image`/`generate-speech`/`transcribe-audio`) and the Ori eval-harness pair.

**No "top weekly / rising" view exists upstream for us**: daily popularity comes from the MCP
rankings tool; *new* models come from the scout's weekly `/models` diff. A 1–2-week riser view
would be a derivation over retained daily-rankings snapshots (rotation store) — not built.

## Rules

### Failure taxonomy — strike vs round vs key-retry

**Rule:** Infra failures (harness-death, auth-storm, timeout, provider 404/5xx, budget-403-account)
are **strikes** — recorded per (task, model), consumed immediately on the next re-dispatch without
consuming a round. Logic failures (reviewer CHANGES_REQUESTED, CI red) are **rounds** — bounded at 5
(ADR-127), escalate to `agent/blocked` after exhaustion. Key mint failures (budget-403-key,
budget-exhausted-key) are **key-retry** — same model, fresh key, same round.

**Enforcement anchor:** `argocd/resources/openrouter-proxy/router.py:STRIKE_CLASSES` (live 6 entries:
`{harness-death, auth-storm, timeout, provider-5xx, no-pr, unknown}`)

**Evidence query:**
- Strikes recorded: `router_strikes_total` gauge per (stack, task, model)
- Strike filtering in chain walk: grep `agent_run_phase` logs for strike comments
- Test: `agents/replay/fixtures/strike-taxonomy` baseline

**Live classes at master:** `{harness-death, auth-storm, timeout, provider-5xx, no-pr, unknown}` (6 entries)

**Unenforced:** The `turn-cap` and `tool-loop` classes (#1665, PR #1677) + per-cell `goose-32602-truncation`
(operator 2026-09-14 direction, no owner) are proposed but not yet in the served router. They reach
master at Goal #1640 theme 1 assembly.

---

### Strike enforcement per-task

**Rule:** A strike blacklists a (task, model) pair only — never the model fleet-wide. The ledger's
FU-057 pivot (model-health across all tasks) is the fleet-wide blacklist vehicle.

**Enforcement anchor:** `argocd/resources/openrouter-proxy/router.py:route()` filters candidates on
task-scoped strikes + health state. Serving-shaped classes (provider-5xx, timeout, auth-storm)
exclude the (model, provider) pair specifically (PR #1685, Goal #1640 theme 1).

**Unenforced:** The enforcement mode flag `ROUTER_STRIKE_ENFORCE` (#1666, PR #1685) is deleted from
the router code on `goal/1640-router`, reaching master at Goal #1640 theme 1. Today the flag is
read but not acted on (live at `router.py:66`); the rule stands regardless.

**Evidence query:** `/router-status` → `strikes_applied` per decision; `router_decisions` log with
`reason: strike` + `detail: "<model>"`.

---

### Fallback chains, per-stack

**Rule:** A stack declares a primary model + ordered fallback chain in `agents/stacks.json`
(`workerModel` + `workerModelFallbacks`). Chain entries must advertise `tools` support (registry
check); reasoning models (`deepseek-r1*`) stay out; `openrouter/auto` at most LAST.

**Enforcement anchor:** `agents/stacks.json` is the authoritative source; launcher validates entries
against the registry on every dispatch.

**Evidence query:** Chainless stacks (no chain, `workerModel` omitted) consult the router's
`model_tiers` rotation instead.

---

### Live model registry, not a price table

**Rule:** The effective input price is `(1−h)·prompt + h·cache_read` where `h` = measured cache-hit
from the ledger. The primary basis is **market effective price** (30d traffic-weighted, OpenRouter
`/api/frontend/v1/stats/effective-pricing`), falling back to the h-blend for unmeasured providers.

**Enforcement anchor:** `estimate_budget.py:pinned_provider(market=)` and the proxy's
`compute_pin:ranked` key. Test: `agents/replay/fixtures/pricing-matrix`.

**Evidence query:** `router_generation_cost_usd_total{model, provider}` + `router_observed_cache_hit{model}`.

---

### Provider pinning per-session

**Rule:** Cache lives at the provider — routing must remain per-session, not per-request.
Dispatch picks the effective-cheapest cached provider (M3 data, with uptime floor ≥ some threshold)
and injects `provider: {order:[...], allow_fallbacks: true, max_price: {...}}` into the request.

**Enforcement anchor:** Goose: egress proxy rewrites body (`argocd/resources/openrouter-proxy/`,
wired as `OPENROUTER_HOST`). OpenCode: `opencode.json` `options.provider`.

**Evidence query:** Request logs showing `provider.order` matches endpoint tag slugs, not display names.

---

### Attribution: served model, served provider, cache-hit %

**Rule:** Per-request, record: served model (resolved by router), served provider, measured
cache-hit % (from OpenRouter `/generation` record), error_class, strike count. Attribution feeds
the FU-057 pivot for model-health re-grading.

**Enforcement anchor:** Proxy harvests `/api/v1/generation` records into `router_generation_cost_usd_total`,
`router_observed_cache_hit` gauges; launcher POST `/report` records all dimensions.

**Evidence query:** `/generation?id=` API (per-request cost + provider); aggregated in the ledger.

---

### Router verdict carriers and their coverage

**Rule:** Four carriers cover distinct routing contexts:

| carrier | context | policy |
|---|---|---|
| `openrouter/fusion` | audit/research/planning | server-side panel, dual-model, web-reach |
| `openrouter/pareto-code`, `bodybuilder` | (not used) | do not advertise tools |
| `openrouter/auto` | last-resort lottery | last chain slot only, cap-bounded |
| `openrouter/free` | xs/sm tasks, free trials | no-cost exploration, dodge vanishing models |

**Enforcement anchor:** Router filters by class eligibility; scout/canary gate verdicts (FU-095).

---

### Model scout — variant filtering, canary verdicts, pool curation

**Rule:** Weekly scout refresh:
1. Filters `:batch` and variant re-listings (one digest row per BASE model).
2. Cross-checks benchmarks (AA indices → capability floor per class).
3. Canary probes: a typed verdict (error_class) that is evidence-bearing only if `clean` or NOT in
   the non-evidence set (`harness-death, auth-storm, timeout, budget-403, mint-failed, key-never-minted,
   void, no-stats, unknown, suspect-infra, inconclusive`).
4. Pool curation: ranked, family-deduped, disjoint bands (`regular`, `premium`, `ultra`, `instrument`),
   deeper than any plausible slot ask, refreshed weekly from capability × market × effective price × rail-compat.

**Enforcement anchor:** `agents/model-scout.sh` stages 1-4; replay against `agents/replay/fixtures/scout-*`.

**Unenforced:** The benchmark MCP call (`scout_get_model`, `$SCOUT_MCP_KEY`) is env-gated; production
today marks all candidates `unbenched` (pending manifest env wiring).

**Evidence query:** Digest posted weekly to slack/tracker; canary verdicts land in router store.

---

### Router class scoring — deterministic lookup, three feeds

**Rule:** Class is a zero-data deterministic lookup (role × task-label × repo-type × agent-budget),
made at authoring/scan time. Scoring uses three feeds:
1. **capability** (per-model release) — external benchmarks → eligibility floor
2. **price + reliability** (days) — market effective price + provider_events + canary verdicts → ordering
3. **own outcomes** (weeks) — run_reports/strikes per (class, model) → correction

The `/route` pick: (chain ∩ class-eligible − deny − task-strikes − health-broken)
→ order by effective price → 15% jitter band (exploration budget).

**Enforcement anchor:** `model-classes.json` (git-owned POLICY half) + proxy `_capability_tick`
(AA indices → capability table). Test: `agents/replay/fixtures/class-routing-*`.

**Unenforced:** Workload profiles + estimator folding (operator direction 2026-08-18, Goal #1640).

---

### Chainless stacks — routerMode, class-rooted fallback

**Rule:** A stack with no chain (`workerModel` omitted) is chainless — every dispatch is routed from
the rotation universe (`model_tiers` ∩ rankings, class floors, strikes, cooldowns) on an authoritative
route (`routerMode: authoritative` on the stack). Router fail-open is excluded — no hardcoded default
fallback.

**Enforcement anchor:** Launcher refuses dispatch without routed verdict (PR #801 on coordinator;
agents/agent-session.sh dispatch path).

**Enforcement evidence:** `router_decisions{stack,outcome}` for chainless stacks.

---

### Coordinator, reviewer, retro, responder routing — role-specific class and override

**Rule:** Every role routes via `/route`:
- **Coordinator/dispatch:** `goal-decompose` class (subscription rail, reasoning tier)
- **Reviewer:** `review` class (sonnet, subscription rail)
- **Retro:** `retro` class
- **Responder:** `responder` class

Explicit CLI `--model` overrides routing (resolve-model --model). Retro `--cell` model is an
explicit arm override (experiments do not jitter). `AGENT_MODEL` env overrides all.

**Enforcement anchor:** Launcher argument parsing (agents/agent-session.sh, agents/coordinator-session.sh);
resolve-model fallback logic. Test: `agents/replay/fixtures/model-override-*`.

---

### Cost ladder across rails — free → subscription → paid

**Rule:** Router picks the cost-optimal option across all rails by true marginal cost:
1. **:free OpenRouter** where (class, model) cell is proven.
2. **Claude subscription** while headroom exists (5h/7d utilization < threshold ∧ semaphore free);
   marginal cost ≈ $0.
3. **Paid OpenRouter** as last resort.

Decision is per (class, urgency) cell; ladder is learned from own-outcomes, not manually tuned.
Shadow-mode log shows disagreements with serving pick (P4 flip discipline).

**Enforcement anchor:** Router `ladder_cells` table in store + `/router-status` → `ladder_cells`.
Served walk: `decision.model`, `decision.rail`. Shadow log: `decision.shadow`.

**Unenforced:** Urgency parameter and per-cell start-tier in shadow (#159, reaches master at Goal
#1640 theme 1).

---

### OpenRouter capacity down — degrade to subscription

**Rule:** When OpenRouter account cannot buy anything (credit floor, hard-402, cross-model 429s ≥2
in window), degrade `class=fix` rides to `claude/haiku` (subscription-fallback). Bounds:
- class=fix only (research/adhoc defer)
- semaphore-bounded (existing FU-088 latch applies)
- per-stack opt-out (`subscriptionFallback: false`)
- `modelDeny` binds (don't hand a stack a model it refused)

**Enforcement anchor:** Proxy `_or_capacity_*` block; launcher triggers:
1. `/route` defers `or-capacity-down:*` (authoritative only)
2. `/router-status` → `.openrouter_capacity.down` (all modes)
3. `/router-status` → `.openrouter_capacity.credit_usd` < floor (all modes)

Test: `agents/rail-degrade-replay.sh` (CAP*, FAILOPEN* cases).

---

### Research routing — deterministic slot draws, curated pools

**Rule:** Research process draws models deterministically from curated class pools by (class, slot)
with `jitter: false` (no random band, stable tie-break). Pools are git-owned in `model-classes.json`
(version, four disjoint bands), enforced at edit time by `devbox run router-self-test` (no band
overlap, no invented ids, no family repeats within band).

A drawn-but-unusable slot defers with reason (cooldown/capacity/deny), never silently slides.

**Enforcement anchor:** `router.draw_slot()` + test `agents/replay/fixtures/research-draw-roster`.
Caller (`agents/research-fanout.sh`) walks to `slot=N+1` itself.

---

### Provider selection — priced per successful job, quality tie-break

**Rule:** Expected cost = effective $/M × expected-tokens + P(fail | provider, model) × overhead-cost.

**Class policy:**
- **cheap coding (exacto)**: Auto Exacto (upstream) owns provider ordering; no pin injection; keep only `max_price`
- **priced (research/audit/weave/judges)**: `pin-v2` = M4 pin + 15% jitter-band + serving-quality tie-break
  (native/fp8 over fp4 → Exacto benchmark score → market cache-hit) + benchmark floor + tool-error floor
  + (model, provider) pair-cooldowns
- **experiments (arms)**: explicit `@<provider_slot>` or `@<slug>`, no fallback

**Enforcement anchor:** `model-classes.json` `provider_policy` + proxy `compute_pin:ranked` (priced classes)
+ proxy tool-call validator (pair-cooldowns).

**Unenforced:** Live tool-call-error floor from upstream stats feed (#1668, lands with theme 1).
Matrix A/B re-admission (#1667).

---

## Related reference

- **History + design journey:** [`../spikes/model-routing-history.md`](../spikes/model-routing-history.md)
  (investigation sections §M1–§M14, design rationale)
- **Ledger + observability:** [`observability-and-retro.md`](observability-and-retro.md)
- **Brief & launcher:** [`../../agents/coordinator/README.md`](../../agents/coordinator/README.md)
- **Architect decision:** ADR-087 (egress proxy), ADR-094 (dispatch determinism), ADR-096 (router),
  ADR-104 (research reproducibility), ADR-115 (provider quality)
