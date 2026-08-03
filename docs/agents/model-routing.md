# Model routing — chains, strikes, and a live registry (not one hardcoded model)

**This doc owns model choice** — failure taxonomy, fallback chains, the live registry, provider
pinning, attribution, the scout, and the task-class pilots. Born from the oracle-fleet issue #1
postmortem and the 2026-06-29 qwen cost autopsy (both in §"The problem, from evidence").

**Where the machinery lives:** the registry is `estimate_budget.py` (cached `/models` +
`/endpoints`, cache-aware effective price, `--lookup`); strike bookkeeping is `AGENT_STRIKE`
comments from the launcher; provider injection and the router/budgeter are the egress proxy
(ADR-087, ADR-096). Companions: [`observability-and-retro.md`](observability-and-retro.md) (the
ledger this feeds) and
[`../../agents/coordinator/README.md`](../../agents/coordinator/README.md) (the brief that
executes it).

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
| `GET /api/v1/credits` | account balance (breaker floor `OPENROUTER_MIN_CREDIT`) | — |
| `GET /api/v1/generation?id=` | billed `total_cost` + native tokens + provider per request | same session key works; feeds `router_observed_cache_hit` |
| `GET /api/v1/activity` | account-wide usage | **management-key only** — not worth holding one in-cluster (FU-095 backfill idea parked) |
| frontend `/api/frontend/v1/benchmarks` | model quality scores | **session-cookie-gated, API key 401s** (2026-08-02) — see MCP row |
| MCP `https://mcp.openrouter.ai/mcp` | `list-daily-model-rankings` (rotation feed, top-30 daily, live since 2026-07-27), `list-models`/`get-model`, `search-docs`, **`list-benchmarks`**, **`list-task-classifications`**, `get-endpoint-uptime-history`, `list-presets`/`get-preset` | standard API key works for rankings (no OAuth dance, 2026-08-02); full tool set via OAuth (7-day key, $10 cap, includes BILLABLE `send-message`). Probed 2026-08-03 (OAuth): `list-benchmarks` sources = `artificial-analysis` (AA intelligence/coding/agentic composite indices, ~126 models) **and `openrouter` — OpenRouter's OWN evals (gpqa_diamond accuracy + $/task), i.e. the formerly session-gated frontend data**; `list-task-classifications` = 7d traffic share per task tag (incl. `code:devops_config`, `devops`, `security_audit`, `research_report`) with top-10 models each; `get-endpoint-uptime-history` = 72h hourly per-provider uptime **with quantization in the endpoint label** (fp8/fp4 — the §M4 staleness/quant filter's data). **Probed 2026-08-03: the standard account key pulls `list-benchmarks` AND `list-task-classifications`** (jail replay of the proxy's exact `_mcp_call` shape with the `router-account-key` Secret) — the scout's weekly capability/market pull is fully automatable server-side; OAuth is only needed for the interactive/billable tools |
| provisioning keys API | mint per-run capped keys (the ADR-081 runtime-key design) | scout canary keys ride this with `only-free` guardrail (FU-024) |

**No "top weekly / rising" view exists upstream for us**: daily popularity comes from the MCP
rankings tool; *new* models come from the scout's weekly `/models` diff. A 1–2-week riser view
would be a derivation over retained daily-rankings snapshots (rotation store) — not built.

## The problem, from evidence

Three incidents, three different lessons, one root cause — **the worker model is a single hardcoded
constant with no feedback loop**:

1. **qwen $5.79 on a ~$0.30 task (2026-06-29).** No `provider` field → OpenRouter's default routing
   (a 1/price² *lottery*, not a floor) drew AtlasCloud at ~$1.15/M effective, **0% caching**, for all
   187 requests. Lesson: the *effective* price (provider + cache-read price × hit rate) is the only
   real price; headline price and "reliability" routing both mislead.
2. **owl-alpha 404 mid-run (2026-06-30).** The cloaked free model was rotated out. The reaction was
   the current doctrine — "don't chase free/cloaked, pick ONE cheap reliable paid model" — hardcoded
   into the brief, the estimator table, and the launcher.
3. **oracle-fleet issue #1 (2026-07-09).** That ONE reliable model (deepseek-v4-flash) died 2 of 4
   rounds to a systematic ~15k tool-call truncation that recipe rules can't fix (TICK-LOG finding A).
   r3's *triple infra failure* consumed the last round → `agent/blocked` → a human, ~12h later, for
   something no human decision was needed on. **The round budget was spent on infra, not the task.**

The doctrine from incident 2 is now a **stale remembered status** (the exact failure mode the
homelab CLAUDE.md warns about for SERVICES.md): the "≈8 rpm free tier" figure is from 2026-06-30,
free-tier limits are account-balance-dependent, and — measured live 2026-07-09 — there are **19
`:free` models advertising tool support**, including `tencent/hy3:free`. Meanwhile the "reliable"
paid pick is the one systematically failing. Reliability is a *measurement*, not a constant.

## Design: three rules

1. **Rounds ≠ strikes.** A *logic* failure (reviewer `CHANGES_REQUESTED`, CI red on the change) is a
   ROUND — bounded at 3, then `agent/blocked`, because that escalation is genuine: the task is
   ambiguous or hard, a human must look. An *infra* failure (harness-death/truncation, auth-storm,
   provider 404/5xx, timeout) is a STRIKE — it consumes **no round**, blacklists that model **for
   this task only**, and triggers an **immediate same-tick re-dispatch** on the next model in the
   chain. A model having a bad day is never a human's problem, and never waits 12h (the free model
   that failed may not even exist by then).
2. **Blacklists are scoped; only the ledger blacklists globally.** A strike is per `(task, model)`.
   The global call ("drop deepseek-v4-flash as primary") comes from the FU-057 **model-health pivot**
   (model × success-rate × harness-death-rate × $/successful-issue) — evidence across tasks, not one
   bad day. Failure classes are task-shaped (deepseek's truncation bites file-*recreation*, not small
   diffs), so the pivot should carry a task-size/class dimension too.
3. **Caps bound the tail, strikes cheapen failure, effective price optimizes the median.** The
   per-session `budgetUSD` key is the hard guardrail (a repeat of the $5.79 run dies at its cap).
   Strikes make a failed model attempt cost one re-dispatch, not a round or an escalation. That is
   exactly what makes *trying* free/new/pinned-provider options rational — the downside collapsed.

## Mechanism

### M1. Failure taxonomy → two counters

Maps 1:1 onto the `error_class` shipped with FU-057 (live in `agent-session.sh` finalize):

| error_class | counter | reaction |
|---|---|---|
| `changes-requested`, `ci-failed` | **round** (max 3) | next round, same chain position |
| `harness-death` (goose `-32602`), `auth-storm` (401/403), `timeout`, provider 404/5xx | **strike** per (task, model) | same round, next chain model, re-dispatch NOW |
| `budget-403` | neither | estimator/cap problem → escalate (the existing ⚠ path) |

Chain exhausted (all models struck for this task) → `agent/blocked` with the strike list in the
comment — that IS worth a human.

### M2. Fallback chains, owned by the stack

`agents/stacks.json` gains an additive `workerModelFallbacks: [...]` next to `workerModel` (=
primary). Per-stack policy, exactly what the `AgentStack` claim's "model tiers" slot (FU-048) was
reserved for; the JSON stand-in carries it until the XRD lands. Rules of thumb: chain entries must
advertise `tools` support (registry check, M3); free entries are fine anywhere in the chain now that
a failure = one strike; reasoning models (`deepseek-r1*`) stay out (slow, verbose, pricey);
`openrouter/auto` at most LAST (see M6).

### M3. A live model registry, not a price table

`estimate_budget.py`'s static `_MODEL_PRICE` becomes a fetch (cached daily, e.g. in the
`agent-transcripts` bucket next to the ledger):

- **`GET /api/v1/models`** — discovery: id, context, headline pricing, `supported_parameters`
  (**filter: must contain `tools`**).
- **`GET /api/v1/models/<id>/endpoints`** — per-provider prompt price, `input_cache_read` price,
  `uptime_last_30m`. The number the estimator uses is the **effective input price**:
  `min over cache-supporting providers of (1−h)·prompt + h·cache_read`, with `h` = measured cache-hit
  from the ledger (start at the autopsy's 0.8; the estimator's `cache_hit` param already exists).

Measured 2026-07-09 for qwen3-coder, why this ordering matters — effective @ h=0.8: Venice **$0.10**
(headline $0.35) < DeepInfra $0.14 ($0.30) < Google $0.22 ($0.22, no cache) < WandB $1.00 (cache-read
= full price). Neither the headline-cheapest nor the reliability pick is the effective-cheapest.

**Upgraded 2026-07-27 (ADR-096 addendum 2): the primary price basis is now the MARKET effective
price**, not the assumed-h blend — `/api/frontend/v1/stats/effective-pricing?permaslug=` returns
each provider's 30d traffic-weighted effective input price with its REAL cache hit rate (what
customers actually paid). `compute_pin` (proxy) and `pinned_provider(market=)` (estimator) use a
provider's market row when present and the h-blend only for unmeasured providers; pins carry
`basis: market|list`. The harvested per-request `/generation` costs (M5) validate it end-to-end.

The registry IS code now (this doc's header — `estimate_budget.py --lookup`); the
`--price-per-mtok` override remains the escape hatch that unblocks any
model today: fetch the price live and pass it (the brief carries the recipe). A `$1.0/M` default in
the verdict means "unpriced", not "forbidden".

### M4. Provider pinning per session (the FU-018 leg)

Cache lives *at the provider*, so per-request routing that bounces providers destroys it — pinning
must be per **session**: the dispatch picks the effective-cheapest cached provider (M3 data, with an
uptime floor — Google Vertex at 37% uptime is a trap) and pins `provider: {order:[...],
allow_fallbacks: true, max_price: {...}}`. Ranked levers from the autopsy stand: **caching provider >
cheaper provider > fewer requests**. Where to inject (unchanged from FU-018, now load-bearing):
opencode = `opencode.json` `options.provider` (works today); **goose cannot carry provider prefs** →
the ADR-081 egress proxy rewriting the request body is the universal home (**v1 LIVE 2026-07-09**:
`argocd/resources/openrouter-proxy/`, wired as goose's `OPENROUTER_HOST`; since 2026-07-17 the
proxy is ALSO the subscription headroom gate — FU-088: 429 latch, 80%-utilization deferral,
semaphore, credit floor, the Grafana claude-subscription panels; creds + Cilium stay
FU-018/FU-020). ⚠ Measured: `provider.order` matches the endpoint **tag's base
slug** (`atlas-cloud`, `deepinfra`) — display names (`AtlasCloud`) silently no-op. Free models sidestep M4
entirely ($0 either way) — one more reason they front the chains for small tasks.

### M5. Attribution (the FU-057 tie-in)

Dynamic routing without attribution would blind the very ledger that makes blacklist calls. Per run,
AGENT_RUN_STATS/manifest/ledger must record: requested model, **served model** (router runs resolve
to a real model), **served provider**, measured **cache-hit %**, `error_class`, strike count. Source:
the OpenRouter activity/generation API (already in FU-057's scope for per-request splits). Worker
`cost_usd` → Prometheus stays as planned. **LIVE at request granularity 2026-07-27 (ADR-096):**
the egress proxy harvests every forwarded completion's `/api/v1/generation` record — billed
`total_cost`, served model+provider, `native_tokens_cached` (the measured check on the h=0.8
assumption) — into its router store (`router_generation_cost_usd_total{model,provider}`,
`router_observed_cache_hit{model}`); the account `activity` API is management-key-only, rejected.

### M6. Routers — verdict (verified against the API 2026-07-09)

- **`openrouter/pareto-code`**, `bodybuilder`: do **not** advertise `tools` → presumed
  unable to drive a goose/opencode worker. One manual probe to confirm the metadata, then park.
- **`openrouter/fusion`** — RE-ASSESSED 2026-07-27 (operator find; the 07-09 "no tools" parking
  is stale — the fusion tool now attaches to the outer model): server-side PANEL deliberation
  (≤8 models parallel + judge synthesis, panel models get server-side web_search/web_fetch),
  ~4-5× single-completion cost. **Candidate chain HEAD for the audit/research/planning task
  class only** (FU-095(a)/FU-105): it mechanizes the dual-model directive in one call and gives
  the researcher web reach WITHOUT widening pod egress on the OpenRouter rail. `analysis_models`
  is a REQUEST param → panel pinned launcher-side (ADR-094), recorded for M5 attribution;
  retro evidence suggests a cheaper panel (deepseek-v4-pro + kimi + one premium) over the
  premium default. NEVER a fixer-lane entry (cost; tool-driving through goose untested).
- **`openrouter/auto`**: advertises tools, but it's a paid model lottery — you cede provider AND
  model choice, i.e. the $5.79 incident as policy. Last chain slot at most, cap-bounded.
- **`openrouter/free`**: a **free router with tools** — the provider/price lottery is harmless at $0,
  and it dodges "this free model vanished today" faster than our ledger can. Strong scout/chain
  candidate for xs/sm tasks.

### M7. The model scout (new, small)

The scout is a **role** (dispatch-on-schedule family — machinery inventory in
[`roles.md`](roles.md)); its routing content stays here. A weekly reflex (Argo CronWorkflow
sibling of review-reflex, per ADR-093): diff `/models` against the known set; filter
tools-capable + (free or ≤ price ceiling); run each newcomer on a **canary task** (a small, closed,
known-good issue — same pattern as the oracle free-tier canary); write the outcome to the ledger.
Newcomers graduate into chains with evidence, not vibes. Free scout keys want **FU-024**
(`guardrail: only-free` actually enforced) so a scout key can't spend. **The FU-095 rotation
("what's currently good", not just "what's new") is fed since 2026-07-27 by the router pulling
OpenRouter's documented MCP `list-daily-model-rankings`** (daily popularity by token volume,
standard API key — ADR-096 addendum 2) into its rotation store; the scout's canary stays the
safety probe for rotation entrants, and canary verdicts land in the same store (`POST /rotation`).

### M8. The router's class scoring — how "auto" happens without the data problem (ADR-096 /route)

Direction 2026-08-02 (operator conversation; ADR-096 has pointed here since P1). The worry this
section answers: *"openrouter/auto decides per prompt; I'll never gather enough data to build
that."* Correct — and unnecessary. `auto` needs per-prompt difficulty inference because its
requests arrive unlabeled. **Ours arrive pre-classified**: every dispatch unit already carries
role ([`roles.md`](roles.md)) × `task/*` label (FU-114 — one label, N consumers) × repo-type
(`-iac` vs app) × `agent-budget/*`. Class assignment is a **zero-data deterministic lookup**
(`model-classes.json` `role_defaults` + `label_map`), made at authoring/scan time, never inferred
in the data plane (ADR-094). What remains is scoring ~10 candidate models × ~5 classes — and that
splits into three feeds with different time constants, none of which needs "enough data":

| feed | time constant | source | role in the pick |
|---|---|---|---|
| **capability** | per model release | external benchmarks (someone else's millions of samples) | **eligibility floor** per class |
| **price + reliability** | days | market effective price + passive `provider_events` + canary verdicts (all live, zero spend) | **ordering + filter** |
| **own outcomes** | weeks | `run_reports`/strikes per (class, model) — the FU-057 pivot | **correction** (catches benchmark-maxxing) |

The /route pick is then: (chain ∩ class-eligible − claim deny − task strikes − health-broken)
→ order by effective price → uniform pick in the 15% jitter band (the exploration budget that
keeps the outcome feed alive — cells need dozens of samples for a coarse works/flaky/avoid
verdict, not millions). Benchmark axes map to classes, not one score: **IFBench** ≈ recipe
compliance (coding), **τ²-Bench** ≈ agentic tool loops (the closest public proxy for "can it
drive goose"), **GPQA/AA-LCR/HLE** ≈ the research/audit reasoning tier. ⚠ Probed 2026-08-02:
OpenRouter's own benchmark data (`/api/frontend/v1/benchmarks?permaslug=`) is **session-gated**
— a standard API key 401s (unlike effective-pricing/MCP), so the source is either the
Artificial Analysis API (documented, free key — an operator mint) or a **curated snapshot in
`model-classes.json`** refreshed by the weekly scout digest (start here: capability changes per
release, not per day, and graduation-stays-human already reviews that digest).
**Un-gated 2026-08-03 (MCP probe): the source question is closed.** MCP `list-benchmarks`
serves both the AA composite indices (`intelligence_index`/`coding_index`/`agentic_index` per
model — the IFBench/τ²-Bench/GPQA proxies are folded inside AA's composites, so the axis
mapping simplifies: coding_index → coding floor, agentic_index → tool-loop floor,
intelligence_index → research tier) *and* OpenRouter's own evals (gpqa_diamond accuracy +
measured $/task — a research-tier floor AND a cost sanity check in one row). The curated
snapshot as delivery vehicle was superseded the same day — **BUILT 2026-08-03 with the router
store as the vehicle**: the standard-key probe made the server-side pull free, so the PROXY
pulls weekly (`_capability_tick` beside the rankings daemon — AA indices → `capability` table,
task-classification top-10s → `task_market`) and `/route` filters per class against
`class_floors` in `model-classes.json` (the git-owned POLICY half; permissive on missing data;
`capability-floor:` skip reasons visible in shadow decisions until the P4 flip). Nothing calls
MCP in the request path. A fourth, cheaper prior from
the same probe: `list-task-classifications` gives 7-day market share per task tag with each
tag's top-10 models — `code:devops_config`/`devops` is a ready-made market prior for the
iac-lane chain (and it surfaces `:free` models with real production usage in the class, e.g.
`nemotron-3-ultra-550b:free` and `ling-3.0-flash:free` in devops/coding tags — rotation
candidates the new-model diff missed).

### M9. Per-stack routerMode + chainless stacks (ADR-096 P4/P5 knobs, 2026-08-03)

`routerMode` on the AgentStack claim (`shadow` fleet default | `authoritative` | `off`) sets
`AGENT_ROUTER` per stack — the launcher reads the stacks.json mirror row; explicit env still
wins. `workerModel` is now OPTIONAL: a claim with no chain is a **chainless stack** — every
dispatch is routed from the rotation universe (`model_tiers` ∩ rankings, class floors, strikes,
cooldowns), and the launcher REFUSES a chainless dispatch without an authoritative routed
verdict (the hardcoded default model never silently stands in; router fail-open excluded).
First consumer: the **circles pilot** (FU-095 P5 ruling — the router is tuned until that
project works; the P4 fleet flip rides its evidence).

**Latency is an ordering dimension, not just price (operator + field evidence, 2026-08-02).**
The free tier makes this acute: every `:free` model prices at $0, so the whole free set lands in
ONE jitter band and price cannot separate them — yet measured turn shape differs wildly
(laguna:free ~306s wall-clock/turn emitting ~3.5k output tokens — ~9× deepseek's ~400 — vs
ling:free's snappier turns). Two doctrine points: **(a) advertised page percentiles are not our
workload** — the model page's e2e P50 (~7-9s laguna) reflects the site's median request; agentic
turns (large context, 16k max_tokens floor) sit at the advertised P95–P99 *by construction*
(Helsinki P99 602s ≈ our steady 306s), so ordering uses OUR harvested evidence, never the page.
**(b) the store's `latency` field is TTFT, not duration** (laguna TTFT 1.6s avg while wall-clock
was 306s) — true tokens/sec needs the `/generation` record's `generation_time` harvested
(homelab#22 build). Once present: within a jitter band, tie-break on measured full-duration
tokens/sec per (model, provider), with per-class tolerance (a `dispatch`-class unit needs fast
turns; a `heavy` overnight ride tolerates slow-but-cheap). Verbosity (output tokens/turn) is
itself a latency AND cost factor — it belongs in the same evidence row. Cache hit is NOT a
latency defense: it accelerates prefill only (laguna: 94% cached paid / TTFT 1.6s, yet ~11-12
tok/s DECODE × 3.5k-token outputs = the 306s turns) — the tie-break metric is decode
tokens/sec, which cache cannot flatter. (Page location tabs = client vantage segments — a
single-provider model shows several — with each segment's own workload mix; another reason the
page is never the evidence.)

**Per-stack and per-task control (operator ruling, same conversation):** projects blacklist
independently — the AgentStack claim gains `modelDeny: [...]`, composed into the /route filter
launcher-side (cluster-wins claim semantics, same seam as the chain). Per-task override rides
labels, not new machinery: `label_map` already maps `track/iac`→class and
`agent-budget/xs`→prefer_free; `task/research`→`research` class gives FU-105 its reasoning tier
+ `openrouter/fusion` head + dual-model without touching the coding lane, and an explicit
`model/<alias>` issue label is the "--model wins" escape hatch, issue-shaped. If per-prompt
difficulty ever matters, it enters as a coordinator-scan **labeling** step (auditable, one
label) — never request-time inference in the proxy.

## The sleep-stack pilots — task-class routing + multi-harness evidence (FU-095)

Direction 2026-07-25. The downstream consumer is the IdP project's **reasoning** agents (auditing,
requirements, monitoring — *not* coding), so the pilots have to produce evidence about a class of
work the coding lane's rules were never written for.

**Three operator corrections that shaped it:**

- **Sleep specs + evidence are a prerequisite, not optional.** Comparable model results across
  projects need the same evidence discipline; without specs the loop can't run reliably on sleep.
  Sequencing: specs discipline (oracle-style, adapted) lands **with or before** graduation.
- **The candidate source is a maintained ROTATION**, not the scout's new-model diff. The scout
  missed `nemotron-3-ultra-550b:free` — verified: the registry snapshot predates it *and* kimi-k3.
  Diff-only + tools/price filter ≠ "what's currently good". The rotation feeds chains
  continuously; the scout's canary leg stays as the safety probe for rotation entrants.
- **Reasoning tier for audit/review/research task types.** The coordinator README currently *bars*
  reasoning models — a worker-coding rule. The audit/research lane needs its own, including
  **dual-model review** (two models on one audit is worth the tokens here, unlike coding). Budget
  shape for IdP pre-build research: a few review rounds on a large model (e.g. kimi-k3), never N
  full designs from scratch.

**Leg (a) — task-class-aware model choice at dispatch.** Today the model is static-chain +
strike-walk (`agents/stacks.json`, coordinator README §MODEL); availability and price already exist
(§M3 registry, §M4 pinning). The new axis: resolve the chain **per task class** (first
approximation: `agent-budget/*` × `track/*` labels) against the registry + strike/ledger history —
the exact gap §M2 notes ("failure classes are task-shaped… should carry a task-size/class
dimension"), with the FU-057 pivot as the data seam. The first axis of the class is **repo-type**:
an `-iac` devops chain is not an app coding chain ([`iac-lane.md`](iac-lane.md) §Model class).

> **Buy-vs-build, surveyed 2026-07-27 → BUILD the small lookup.** External routers solve
> per-*prompt* difficulty inference (RouteLLM / NotDiamond / openrouter-auto — popularity- or
> classifier-based, and none can read our ledger; the §M6 verdict on `auto` stands) or gateway
> mechanics (LiteLLM / Portkey — which would un-solve the proxy's subscription gate and cred/pin
> injection). Closest fit is **OpenRouter presets** (`@preset/<class>`, server-side chains) —
> dashboard-managed today, i.e. click-ops; watch for API manageability.
> Two registry enhancements adopted from the survey: **(1)** a provider quantization/staleness
> filter in the §M4 pin (the `/endpoints` field — never pin an fp8/stale serving for
> eval-sensitive lanes); **(2)** "sales" need nothing — live effective-price recompute per
> dispatch already captures price drops, and the rotation covers currently-good drift.
> **(3) `openrouter/fusion`** (operator find, same day): a panel-deliberation router — the
> audit/research **class chain head** candidate, mechanizing the dual-model directive in one
> ~4–5× call, with server-side web reach solving part of the FU-105 egress dial on the
> OpenRouter rail. §M6 was re-assessed (the 07-09 no-tools parking was stale). Panel pinned via
> `analysis_models` launcher-side; **never** a fixer-lane entry.

**Leg (b) — multi-harness evidence.** The same task classes across `--harness goose|opencode|claude`,
compared on the FU-057 ledger axes {success-rate, harness-death-rate, $/successful-issue}. This
*is* the recorded ADR-077 trigger ("add Omnigent's meta-harness only if governing multiple
harnesses becomes real") — the pilot supplies the evidence that decision is waiting on.

**Leg (c) — free-model probing of goose error handling.** Extend the model-scout canary shape
(ephemeral only-free capped keys) from trivial closed rides to real sleep xs tasks. This resolves
the live tension between §M2 ("free entries fine anywhere — failure = one strike") and
`stacks.json` `_chain_policy` ("free tiers never fix-chain entries").

Renovate-majors piloting on sleep is **not** this — that's FU-046's existing lane. Prereqs: FU-080
sleep graduation (+ FU-044 before unattended deploys). The router that leg (a) needs is ADR-096,
whose store/decision-API build is tracked there.

**Terminology ruled (2026-07-27), record it in sleep's process docs when the specs land:**
**"system testing"** = logic against real components in kind (Garage + ingester + Grafana +
Playwright, the ADR-082 shape); **"e2e"** is reserved for the actual target environment (synthetic
production traffic). Cf. Fowler's microservice testing pyramid — our "system" ≈ his out-of-process
component / limited e2e.

## The bundle — why these FUs resolved together

_All five archived (2026-07-12…07-25); the table stays as the design rationale._

| FU | role in this design | without it |
|---|---|---|
| **FU-062** (this doc) | strikes vs rounds, chains, registry, scout | the single-model lock stands |
| **FU-057** | `error_class` + served model/provider/cache-hit in the ledger | strikes unclassifiable, blacklists blind |
| **FU-018** | provider pinning injection (opencode now, proxy for goose) | effective price unenforceable → $5.79 repeats (cap-bounded) |
| **FU-021** | goose hard-stop on auth/limit errors | a strike burns its whole session cap in a retry storm first |
| **FU-024** | enforced only-free guardrail | scout/free keys are honor-system |

