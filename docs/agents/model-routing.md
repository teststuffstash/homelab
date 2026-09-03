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
| `budget-403-account` | **strike** per (task, model) | same round, next chain model, re-dispatch NOW — operator top-up needed, not an estimator fix |
| `budget-403-key`, `budget-exhausted-key` | **key-retry** (not a strike) | same round, **same model**, fresh session key — mint defect (FU-202) |
| `budget-403` (residual) | neither | estimator/cap problem → escalate (the existing ⚠ path) |

> **Raw-log fallback path (homelab#871 / PR #879) split `budget-403` into subclasses.**
> The in-pod finalize (`agent-session.sh` finalize) emits the `error_class` that lands in the
> ledger. The raw-log fallback (no structured report) greps the harness run log and emits the
> finer-grained subclasses above. The table now carries the full taxonomy; the subclass note
> from FU-202 (homelab#1233) replaced the temporary bridge.

Chain exhausted (all models struck for this task) → `agent/blocked` with the strike list in the
comment — that IS worth a human.

⚖ **The strike COMMENT stays the store for now — with a named debt for stack consumers
(operator ruling, 2026-08-19).** The per-comment store is deliberate (the ADR-103 stores
channel: start-of-comment anchoring, immutable ordering, greppable by the chain-walk and the
fleet-fault rule — [observability-and-retro.md](observability-and-retro.md) §Part A⁗), and on
homelab it stays as-is: the whole project is about agents, the noise is signal here. But for a
CHAINLESS-STACK consumer it is machine residue on business-focused issue threads. The future
shape — blocked today on the router's storage engine not being settled (state spans the sqlite
router store, pushgateway, and GitHub comments) — is: migrate the strike READERS (the brief's
chain-walk, the ≥2-in-24h fleet rule) to the router store's `strikes` table (already recorded
there since M1a), then demote the GitHub comment to one appended line on the `agent-summary`
index. Replay-first, per the A⁗ channel table's own "stores move later" clause; pick it up when
the storage-engine question settles, not before.

### M1a. ⛔ THE TAXONOMY DRIFTED — strikes are recorded almost never (found 2026-08-07)

**`router_strikes_total = 1` across the whole store**, against three `harness-death` rides on
2026-08-06/07 alone (circles#32 r1+r3, circles#19 r1). The routing built on top of strikes is fine;
it is starved of input.

`router.py:record_report()` does `err = d.get("error_class")` and tests it against
`STRIKE_CLASSES = {harness-death, auth-storm, timeout, provider-5xx, no-pr, unknown}`. But the
launcher (`agent-session.sh`, the `/report` body) sends **two** fields:

| field | value on a goose death | in STRIKE_CLASSES? |
|---|---|---|
| `error_class` | `goose-32602-truncation` | ❌ no — the tested field |
| `outcome` | `harness-death` (= `stats.exit_status` when no PR) | ✅ yes — the untested one |

So the coarse class the set was built for arrives in `outcome`, and the field actually tested
carries a finer sub-type the set never learned. `striked = False`, silently. Note two of the set's
own members (`harness-death`, `no-pr`) are `outcome` vocabulary, so it was never coherent with the
field it is compared against.

**The table above is the proof of intent**: it names *"`harness-death` (goose `-32602`)"* as one
thing. The sub-type was always meant to strike.

**Consequence:** a chainless stack (`circles`: `workerModel: null` → `routerMode: authoritative`)
draws candidates from the rotation pool and filters them on strikes/cooldowns — with an empty
strike table, so it re-picks a model that just died. Observed: `deepseek-v4-flash` re-picked for
circles#19 r2 immediately after r1's harness death. ⚠ Retry works (r2 succeeded), so this is waste,
not a stall — 3 deaths vs 3 clean runs on lg work.

**SHIPPED 2026-08-07 — recording fixed, enforcement deliberately OFF** (operator ruling). The
predicate now matches EITHER field, and `route()` consumes strikes only when `STRIKE_ENFORCE`
(env `ROUTER_STRIKE_ENFORCE`, default `0`). Proven both ways before deploy: off → the struck model
stays eligible (`skipped-for-strike: []`), on → it is filtered. Routing is exactly the behaviour
the loop already had — the difference is that it is now a **decision** rather than an accident.

⚠ **Why enforcement is NOT on, and this is the interesting part.** The bug was *lucky*. Under the
design, circles#19 r1's harness death would have struck `deepseek-v4-flash` for that task — and r2
on **the same model completed the same task**. Running tally on `lg` work: **3 deaths vs 3 clean
runs**, so "N strikes and you're out" is not supported by the evidence; a strike would have bought
a pricier chain entry for a failure a ~$0.04 retry fixes.

**Open question, not decided (operator, 2026-08-07):** for a model this cheap and this flaky,
**fan out N parallel workers and keep the first survivor** may beat both retry-serially and falling
through the chain — N × $0.04 against one attempt on a costlier model, with wall-clock the real
win. That is a policy question the strike DATA now exists to answer; it is why we record before we
act.

**RULED 2026-08-23 (operator, G-A child homelab#783): `ROUTER_STRIKE_ENFORCE` is RETIRED as a
blacklist knob.** The 16-day store read (the #783 memo): six strikes total, five of them one
harness class (`goose-32602-truncation`), enforcement would have changed ~1 decision for cents;
the 3-deaths-vs-3-clean-retries evidence stands. Strikes stay **recorded** (this feed is the
FU-057 pivot's and feed 3's input — recording preceded policy once and must again), and
`model_cooldowns` carries the residual provider 4xx/5xx class. The env's **deletion site is the
`STRIKE_ENFORCE` read + filter branch in `router.py`**, and it rides the G-A legacy-deletion
sweep (chainless-redesign.md build order 6) — dead code until then, nothing sets the env.
Re-open condition: a post-P4-flip strike mix showing a per-model class the cooldowns miss —
re-opens as a NEW design carrying the provider dimension from day one (the #783 thread's
provider-attribution legs: strike records gain the served provider; serving-shaped strikes
exclude the (model, provider) pair and re-run the PRICED pick — never a blind same-model
retry; a model-level verdict needs ≥2-provider evidence). Fan-out graduates OUT of strike
policy to a dispatch-time evidence lane on `:free` models (ROADMAP work map, the G-E
candidate; the #778 thread is the pilot's findings ledger).

⚠ **The self-test could never have caught this** — its fixture put `harness-death` in
`error_class`, the taxonomy's own vocabulary, a shape the launcher never sends (same trap as
FU-115b: a fixture built to match the code instead of the caller). A row carrying the REAL producer
shape is now in `self_test()`, and it fails without the fix.

### M2. Fallback chains, owned by the stack

`agents/stacks.json` gains an additive `workerModelFallbacks: [...]` next to `workerModel` (=
primary). Per-stack policy, exactly what the `AgentStack` claim's "model tiers" slot (FU-048) was
reserved for; the JSON stand-in carries it until the XRD lands. Rules of thumb: chain entries must
advertise `tools` support (registry check, M3); free entries are fine anywhere in the chain now that
a failure = one strike; reasoning models (`deepseek-r1*`) stay out (slow, verbose, pricey);
`openrouter/auto` at most LAST (see M6). A chain that ENDS in `claude/haiku` (sleep, oracle) already
falls to the subscription inside `/route` when the OpenRouter rail is capacity-blocked — §M12 is
what covers the chains that do not, and the shadow-mode stacks whose defer never reaches `/route`.

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

### M7. The model scout — v3: pools + a typed rail-probe canary (redesigned 2026-08-10)

The scout is a **role** (dispatch-on-schedule family — machinery inventory in
[`roles.md`](roles.md)); its routing content stays here. A weekly reflex
(`agents/model-scout.sh`). v1/v2 (catalog diff + digest + a fixer-shaped canary) served the era
when the fixer was the only model consumer; the 2026-08-10 redesign (trigger: digest #234 — 20 of
22 "new" candidates were a platform-wide `:batch` variant rollout of years-old models, and all 3
canaries posted bogus `failed` verdicts, tripping #235; #234 CLOSED as a dud 2026-08-11 — legs
1–2 were the PRECONDITION for the next scout run and shipped 2026-08-11 in homelab#282, and #235's
premise dies with leg 1) rescopes it for the grown selection
surface (§M8 classes, §M9 chainless stacks, §M13 research pools). Legs, in build order (FU-161):

1. **Filter variant re-listings.** ✅ **BUILT** (homelab#282, 2026-08-11). Diff by BASE id (id
   minus `:suffix`) — a variant of a known base is not a newcomer (one digest summary line, never
   N rows). Exclude `:batch` outright: async endpoints cannot serve an interactive session, and
   their discounted headline price is exactly what slips them under the ceiling. Two rules, and
   the order matters: `:batch` goes first and unconditionally, so a `:batch` listing of a
   genuinely new base is still dropped. Within-tick siblings collapse too (two variants of one new
   base = one candidate, represented by the cheapest listing). The snapshot keeps storing FULL
   ids — bases are derived at diff time, so the live snapshot survived the change. Replayed
   against #234's own world in `agents/replay/fixtures/scout-variant-batch-rollout`: 22 → 2.
2. **Benchmark cross-check, one MCP call per candidate.** ✅ **BUILT** (homelab#282, 2026-08-11),
   with one live unknown named below. `get-model` embeds the AA indices; attach them to the digest
   row (capability beside price, so the graduation call has both) and mark benchless newcomers
   `unbenched`. Rank candidates before spending canary slots (free-first, then agentic/coding
   index) — never `head -N` in diff order. Built as `scout_get_model`, the same `_mcp_call` wire
   shape and the same standard-account-key assumption the proxy's capability feed rides, and
   **env-gated on `$SCOUT_MCP_KEY`**: the scout's CronWorkflow env carries no OpenRouter account
   key today, so until that manifest change lands the honest production path is *every candidate
   `unbenched`, digest still posted* — pinned as such
   (`fixtures/scout-bench-unkeyed-unbenched`), because a capability feed that cannot run must
   degrade the digest, never cancel it. ⚠ **Unverified upstream detail:** `get-model`'s
   `arguments` envelope was never probed (the 2026-08-03 probe covered `list-benchmarks` /
   `list-task-classifications`); the call sends the `{request: {…}}` shape its siblings take, and
   a wrong guess returns a JSON-RPC error that is logged verbatim and downgraded to `unbenched`
   (`fixtures/scout-bench-mcp-error`). The first keyed hand-fire settles it in one round.
3. **The canary is a RAIL probe, not a capability probe.** Capability comes from the benchmark
   feed (§M8 feed 1, already pulled weekly by the proxy); the canary answers the one question no
   benchmark can: does this model complete a tool-call loop through OUR stack (harness → egress
   proxy → pinned provider → guardrailed ephemeral key). Rung 1 = the trivial closed ride —
   cents on ANY model, expensive ones included, so it covers pool entrants too; rung 2 = a real
   xs task (FU-095 leg (c)) only for cells a chain actually wants. A canary verdict is evidence
   about a CELL — (model, harness, class) — never about "the model"; verdicts land cell-keyed in
   the same store the own-outcomes feed reads, `source=canary`.
4. **Typed verdicts, two sanity rules.** The verdict carries the launcher's `error_class`, not a
   binary exit status. *Contradiction rule*: canary-fail ∧ benchmark-capable ⇒ `suspect-infra`,
   retry once, else `inconclusive` — never `failed` (2026-08-10: ling-3.0-flash, coding 50.6 —
   above gpt-5.1 — posted `failed` on "echo the README heading"). *Common-cause rule*: the tick's
   canaries (≥2) ALL failing identically = ONE scout-infra datum, zero per-model verdicts —
   whole-set deliberately, never any-subset (#506 ruling, 2026-08-18: a clean sibling refutes
   the scout-infra hypothesis — the stack demonstrably worked — so partial identical-failure
   groups stay per-model and ride the contradiction rule's retry; the ci-red/strike fleet rules'
   any-N≥2 reading does not import here, they have no clean-sibling refuter).

   **Evidence-bearing vs non-evidence partition (FU-161 filing gate, #877).** The shipped
   skip-log gate (`model-scout.sh:476`) cites this section; the partition itself is not a
   sanity rule but the **gate condition** that decides whether a canary verdict counts as
   evidence for graduation:

   - **Evidence-bearing**: `clean` — the model completed a real tool-calling ride — or any
     `error_class` NOT in the non-evidence list below (a genuine *model* outcome). The three
     enforcement sites test the verdict STRING only, so a free-model (`only-free`) canary that
     returns `clean` counts as evidence exactly like a budget-capped one: `.canary` is merged
     into `ranked.json` independent of `.free` (`model-scout.sh:447-448`). On the canary path
     `clean` is in practice the only reachable evidence-bearing verdict — the §M1 model-outcome
     classes (`changes-requested`, `ci-failed`) are PR-ride verdicts and a canary is an adhoc,
     no-PR probe (`model-scout.sh:347-348`);
   - **Non-evidence (rail/platform fault, tells you nothing about the model)**: `void`,
     `no-stats`, `unknown`, `mint-failed`, `key-never-minted`, `harness-death`, `auth-storm`,
     `budget-403`, `timeout`, `suspect-infra`, `inconclusive`.

   A row carrying a non-evidence verdict is withheld from graduation consideration. The
   partition is enforced in three sites in `agents/model-scout.sh`, all in the digest
   assembly section:

   1. The conceptual comment at `model-scout.sh:461-470` (the source of truth for the
      non-evidence list);
   2. `EVIDENCE_CANARIED_N` at `model-scout.sh:472` — a jq `select` that counts models whose
      canary verdict is *not* in the non-evidence set;
   3. `WITHHELD` at `model-scout.sh:474` — the inverse jq `select` that names the models
      excluded from the digest.

   There is no single home for the partition; these three sites are its ground truth. When
   a verdict is added to or removed from the non-evidence list, all three must change.
5. **Pool curation — the §M13 duty.** The scout maintains the named class pools: ranked,
   family-deduped, disjoint bands by convention, deeper than any plausible slot ask, refreshed
   weekly from capability × market (`task_market`) × effective price × rail-compat. Diversity
   lives HERE, at curation time — never in the request path.

Unchanged: graduation into chains REMAINS a human call; a canary failure never fails the tick;
free keys ride FU-024 `only-free`. The FU-095 rotation feed stands as built (MCP
`list-daily-model-rankings` → rotation store since 2026-07-27, ADR-096 addendum 2).

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
verdict, not millions).

⚖ **The FOURTH feed — workload profiles, and the estimator folds into the router (operator
direction, 2026-08-18 — direction, NOT a build decision).** Smart router, dumb consumers: the
router learns each class's empirical shape — rounds (janitor ≈ N historically), tokens/round,
context size, cache-read share — and prices candidates as **expected cost per JOB**, not $/M.
`estimate_budget.py` is already the formula (`rounds × requests/round × context × eff$/M ×
(1−cache)`) with hand-tuned static bands launcher-side; router-resident and measured, it
recomputes automatically when the price table moves — no per-role model preferences hardcoded
anywhere, no stale "who knows what" tuning. Consequences that fall out rather than being
policy: rail affinity (a cache-heavy profile prices brutally on the [Go rail](chainless-redesign.md)'s list-on-raw draw
and cheaply on Anthropic's discounted cache — so "low-cache roles prefer Go" is an OUTPUT);
whole-cycle reservations (retiring the flat $2 cap-tier class behind goal #278's $104 phantom
— ADR-107 cost-rethink direction 4's mechanism). Refinements pinned at sketch time: split by
density (context/turn shape = per-CLASS prior, dense; rounds-to-converge = per-CELL correction,
feed 3's existing data); price per **successful** job (the FU-057 `$/successful-issue` axis) or
fail-fast models Goodhart the pick; profiles are OFFLINE folds over run_reports + the
`/generation` harvest + OTLP `claude_code_*` (scout-tick cadence — never per-request inference,
ADR-094 stands); cold-start falls back to the static bands as priors. Substrate = ADR-107
flip-acceptance 2's accounting work (rail + per-role attribution) — nothing new to collect,
one new fold + the pick formula. Benchmarks (feed 1) and canary/strike/retro evidence (feed 3)
stay filters/corrections on the same pick; family decorrelation (homelab#516) a filter beside
them. Benchmark axes map to classes, not one score: **IFBench** ≈ recipe
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
labels, not new machinery: `label_map` already maps `track/iac`→class,
`agent-budget/xs`→prefer_free, `agent-budget/md`→tier_floor=cheap, and
`agent-budget/lg`→tier_floor=large+never_free (all enforced in /route since homelab#1259);
`task/research`→`research` class gives FU-105 its reasoning tier
+ `openrouter/fusion` head + dual-model without touching the coding lane, and an explicit
`model/<alias>` issue label is the "--model wins" escape hatch, issue-shaped. If per-prompt
difficulty ever matters, it enters as a coordinator-scan **labeling** step (auditable, one
label) — never request-time inference in the proxy.

### M10. The coordinator lane is UNROUTED — and the goal clauses are its reasoning tier

> **⚠ SUPERSEDED IN THE LARGE (2026-08-23, G-A #775 — the role-wiring children landed):** every
> role now routes — coordinator + dispatch units via PR#801 (the goal-model case map became the
> `goal-decompose` class in `model-classes.json`; §IL-T11's anchor moved with it), the reviewer
> via PR#803 (decorrelation consumed as the #516 `/route` primitive, failover literal deleted in
> authoritative mode), responder/retro/fix-debounce via PR#788 (#782). The section's
> launcher-era narrative was trimmed to the what-stands block below (2026-08-26, the S5
> doc-heat pass — a 74-line measured-cold span).

**ADR-096 override rule (settled, #810):** explicit CLI `--model` on coordinator/reviewer = override (route skipped, `resolve-model --model`). Scan-supplied default (`coordinatorModel`) = constraint + fail-OPEN fallback (`resolve-model --fallback`, route consulted). Retro `--cell` model = **explicit override** since #861/PR#864 (cells are experiment ARMS — ADR-104, experiments do not jitter, so the router may never collapse the A/B axis; `resolve-model --model` with `--fallback` kept for validation + the unreachable-proxy literal). `AGENT_MODEL` env = universal override (checked ahead of the route in all roles). Stated once here; the launcher comments cite this section by name.

What still stands from this section (the rest is history — PR#788/#801/#803 wired every
role to `/route` and the launcher case maps died with them; the era's narrative is in git):

- **The AUTHORING-vs-CHECKING axis.** `goal-decompose` runs the reasoning tier (now the
  `goal-decompose` class in `model-classes.json`, subscription rail); reviews stay
  sonnet-class — a review is a review, proven twice on live goal-reviews (2026-08-05) and on
  sleep-tracking#9. **Made a served fact 2026-09-03:** the `review` class carries
  `chain_head: ["claude/sonnet"]` (the third `chain_head` stand-in after goal-decompose and
  dispatch) — until then, on chainless stacks the served walk drew `xiaomi/mimo-v2.5 [market]`
  for reviews and only the FU-188 pin's fallback kept the lane on sonnet. Escalate a specific hard goal with `GOAL_MODEL`
  (`coordinator-session.sh`); never raise a clause's floor.
- **The assembly reviewer must DIFFER from the decomposing model** (issue-authoring leg (c));
  decorrelation is consumed as the #516 `/route` primitive since PR#803.
- **`audit`/`research` classes are the wrong shape for coordination reuse** — both pin
  `rails: ["openrouter"]` with a fusion head; coordination stays on the subscription safety
  net (heeded: `goal-decompose` is its own subscription-rail class).
- ⚠ **A goal small enough for one ride is not a goal** (same ruling era): circles#17
  decomposed to two children while a one-shot arm reached comparable output, so neither the
  fan-out's advantage nor the reasoning tier was ever load-bearing — calibrate goals so
  decomposition and the acceptance judgement actually carry weight
  ([research-and-specs.md](research-and-specs.md) step 5 cites this as its evidence).
- ⚠ **The `dispatch` tier's premise is measured FALSE and deliberately left alone**:
  `tier_thresholds` reads "~30s dispatch units" yet 149/149 coordinator sessions exceeded 30s
  over 7d (p50 105s, p99 1342s) — and its 0.9 utilization threshold makes coordinators defer
  LAST. A whole-lane question; re-open with evidence about what the latch protects.

**Tracked by:** FU-090 (its Operator-deferred line holds the goal-lane status).

### M11. The cost ladder across RAILS — free → subscription-headroom → paid (operator direction 2026-08-08)

The gap the 2026-08-08 starvation night exposed, stated as the target: **the router picks the
"best" option across ALL rails, and the ladder is learned, not configured.** Preference order by
true marginal cost: (1) **:free OpenRouter models** where the dispatch can afford the gamble and
the (class, model) cell has proven itself; (2) **the claude subscription** while there is
definite headroom (it is already paid — marginal cost ≈ $0 — bounded by the FU-088 semaphore +
utilization gates that protect the review/coordination safety net); (3) **paid OpenRouter** as
the reliable spender of last resort. Three missing pieces over M8:

- **The subscription becomes a route CANDIDATE, not a claim knob.** /route's ordering today is
  effective price *within OpenRouter*; the subscription rail enters the same ordering priced at
  ~0 when `5h/7d utilization < threshold ∧ semaphore free`, and infinite when not. homelab#158's
  or-capacity-down degrade is the EMERGENCY case of this same ladder — this section is the
  steady-state generalization.
- **Urgency is a route input.** Free-tier picks risk 429-storms and slow completions (laguna:
  100% "up", 81% 429 for us). A dispatch carries whether it is deadline-tight (ci-red fix rounds,
  goal-chain children with a waiting assembly, review rounds) or backlog-elastic (cosmetic
  sprouts, research spikes, retro digests) — scan/authoring-time deterministic, like every other
  class input (ADR-094: never inferred in the data plane). Tight ⇒ skip tier 1 unless the cell
  is proven-fast; elastic ⇒ tier 1 first, always.
- **The LADDER is learned per (class, urgency) cell.** M8's own-outcomes feed corrects within a
  tier; extend it to tier-START selection: a cell whose tier-1 attempts keep banking clean
  outcomes keeps starting at tier 1; degradations (strikes, deadline blows, retry storms) climb
  the start-tier — and the jitter band occasionally re-probes downward so recovered free models
  get re-discovered. Same store, same shadow-decision visibility, same P4-flip discipline: run it
  in shadow first, flip when the shadow log reads sane. **The operator stops being the ladder's
  tuner — the outcomes are.**

Buildable first leg: homelab#159 (shadow-mode: subscription-rail candidate + urgency input +
per-cell start-tier in the store, decisions logged, no behavior change until the soak reads
clean). Relates ADR-096 (the /route contract), homelab#158 (the emergency degrade), FU-095
(the pilot evidence), FU-088 (the safety-net gates this must never starve).

#### M11a. The shadow leg as built (homelab#159) — what to read during the soak

All three pieces live in `router.py` and run on every `/route` call; **the served walk is byte-for-byte
the one above it** — the ladder is computed from the same filtered candidates and the same capacity
gates, attached to the response as `decision.shadow`, and written to the store. The launcher reads
`.decision/.model/.reason/.basis/.half_open/.retry_after_s` and nothing else, so the extra key is
inert by construction.

| piece | where | what the soak reads |
|---|---|---|
| subscription as a candidate | `_shadow_ladder()` — priced `0.0` when `subscription_ok(tier)` passes, **unpickable** otherwise; a synthetic `ladder.subscription_model` (`claude/haiku`) enters the ordering when the chain names no `claude/*` | `router_shadow_decisions_total{rail,tier,urgency,agrees}`, `router_shadow_subscription_blocked_total{reason}` |
| urgency | `resolve_urgency()` + `urgency_map` in `model-classes.json` | the `urgency`/`urgency_source` columns of `shadow_decisions` |
| per-cell start tier | `cell_start_tier` table, fed by `fold_outcome_into_cell()` from the EXISTING `POST /report` feed | `router_shadow_start_tier{class,urgency}`, `/router-status` → `ladder_cells`, `shadow_24h` |

Three readings had to be pinned down to build it; they are the things to re-argue at the flip:

- **The rungs are ordered by TRUE MARGINAL cost, which is a different axis from the in-rail
  effective $/M.** `free (0) → subscription (1) → paid (2)`; within a rung the existing
  cheapest-effective + jitter-band pick is reused unchanged.
- **Urgency is the prior, the cell is the correction.** `elastic` takes the learned rung as-is (it
  begins at free — "tier 1 first" — and only climbs on our own evidence); `tight` floors at the
  subscription rung until the cell has PROVEN free (`promote_after` banked-clean runs while
  already starting there). Reading it the other way — elastic *forcing* rung 0 every time — would
  make the learned table inert for exactly the half of the traffic it is supposed to teach.
- **A re-probe that banks clean is adopted immediately**, not after `promote_after`. The jitter
  band's whole job is re-discovering a recovered free model; making recovery wait days would
  defeat it. Degradation is the asymmetric direction: a strike at rung *t* starts the cell at
  *t+1*.

⚠ **FU-088 is a BOUND, not a preference, and it is asserted in the self-test**: the subscription
rung is priced unpickable whenever the 429 latch holds, either utilization window is past its
(tier-composed) threshold, **or the semaphore is full** — so the ladder can only ever consume
headroom the reviewer/coordinator lane was already willing to give up. `route()` memoizes the two
capacity gates, so a routed dispatch still costs at most one read of each (§M11's "no new probes"):
what changed is that the subscription verdict is now read on *every* route rather than only when a
`claude/*` candidate survived filtering.

⚠ **Known gap, and it bounds what the soak can conclude:** `agent-session.sh` does not send
`urgency` *or* `labels` in its `/route` body yet, so every production shadow line will read
`urgency=tight (default)` and the (class, **urgency**) table will have only tight cells until the
caller side lands. Per-class rail/rung evidence is unaffected — the elastic half of the grid is
simply not being exercised. That wiring is the next leg (launcher-side, `agents/**`, deliberately
out of #159's `Touches:`); the table it must read already exists and is the same one `/route`
falls back to.

The flip criterion is unchanged and is the P4 discipline: read `shadow_24h` for a few days, and
promote only if the divergences (`agrees=false`) are the ones you would have wanted — the
homelab#158 shape (OpenRouter capacity down → served *defers* while the ladder says
`subscription:claude/haiku`) is the signature to look for.

### M12. Provider DOWN ≠ budget SPENT — the haiku degrade (operator directive, 2026-08-08)

**This amends the standing tiering doctrine** ("workers stay cheap OpenRouter; the subscription is
the coordinator/reviewer safety net" — §M10). The separation survives; what changes is that it is
now a separation under *normal* conditions rather than an absolute.

⚖ **Platform workers STAY on the subscription (operator ruling, 2026-08-12, v1.2 planning).**
The rail-move option (platform workers → OpenRouter, freeing the pool and making `Budget:` real
money) was considered and REJECTED for now: the subscription's 5h/7d windows are budget caps that
live OUTSIDE anything a platform ride can edit, and platform workers are exactly the rides that
can introduce bugs into the OpenRouter cap mechanics themselves (the operator, the proxy, the key
CRs). Independence-from-the-code-under-change is the property that decides it. Consequences: goal
budgets on [the platform stack](agentstack.md) stay cap-phantom until SUBSCRIPTION budgets are built (the "get
subscription budgets working" direction — rides the post-FU-131 rail-aware-summation charter on
#278), and the FU-168 famine fixes carry the throughput load alone.

**§M11 above is the general case; this is the emergency one, and it is what actually shipped**
(homelab#158, in the launcher + the proxy). M11's ladder makes the subscription an ordinary
route candidate priced at ~0 while it has headroom; this section only answers "the OpenRouter rail
cannot buy anything at all" — a narrower, typed condition with a constant answer. When M11's leg
lands (homelab#159) the trigger below becomes one input to the ladder rather than its own branch;
the BOUNDS are the part that must survive the merge, because they are what keeps either mechanism
from eating the safety net. ⚠ #159 shipped SHADOW-only (§M11a), so **this branch is still the one
that acts** — the ladder merely logs that it would have reached the same rail; the trigger folds in
at the P4 flip, not before.

The evening that forced it: OpenRouter went hard-down for workers (the provisioning `keys-modify`
daily limit + a $0.17 balance, openrouter-operator#26) and the **entire fleet's dispatch deferred
for hours**, while the subscription rail sat at 2 of 5 semaphore slots on a fresh Max-20x plan. Every
individual deferral was locally correct and the aggregate was absurd — a loop with an idle rail
waiting on a dead one. The operator's ruling: *the router should have picked haiku.*

**The distinction the fix is built on** — two OpenRouter refusals that used to look alike:

| condition | typed as | reaction | why |
|---|---|---|---|
| the project key's headroom is spent | `openrouter-budget-exhausted` | **stop** (unchanged) | a BUDGET decision; spilling it onto the subscription routes around the ceiling the key exists to impose |
| the ACCOUNT cannot buy anything (credit floor, hard-402, cross-model 429s) | `or-capacity-down:<what>` | **degrade** | an INFRA failure, the same class as a 5xx — and the loop survives those by moving, not by waiting |
| one model is 429ing / struck | `cooldown:*` / `strike` | unchanged (§M1) | a bad model is not a dead provider |

**Where each half lives.** The proxy raises the account-scope condition
(`argocd/resources/openrouter-proxy/openrouter-proxy.py`, the `_or_capacity_*` block): a polled
account balance under `OPENROUTER_MIN_CREDIT`, an upstream 402, or 429s from **≥2 distinct models**
inside `OR_RPD_WINDOW_S` — that last one is how "the account is rate-limited" is told from "this
model is", without guessing at upstream header semantics. It self-heals exactly like the FU-088(a)
subscription latch: the hold expires, and any OpenRouter 2xx clears it early. `/route` then types
its defer with it, and `/metrics` carries `router_openrouter_capacity_down{,_total}` +
`router_openrouter_account_credit_usd`.

The **launcher** (`agents/agent-session.sh`) decides — ADR-094: dispatch params are launcher-owned.
**Three triggers**, because the fleet runs in two modes and the shadow half has to reach the same
facts without the routed verdict:

| # | trigger | mode | what it is |
|---|---|---|---|
| 1 | routed defer typed `or-capacity-down:*` | **authoritative** only | all three legs at once, already decided by `/route` |
| 2 | `/router-status` → `.openrouter_capacity.down` | all | the proxy's own latched account verdict (homelab#194) |
| 3 | `/router-status` → `.openrouter_capacity.credit_usd` under the launcher's floor | all | the FU-088(b) gate's balance hoisted above the harness decision, so the same fact can *act* instead of only deferring |

A shadow-mode routed defer is deliberately NOT a trigger — that would be the launcher quietly
promoting shadow to authoritative.

**Why 2 exists, and why it outranks 3** (homelab#194, operator ruling 2026-08-09). Trigger 3 alone
cannot see the outage that produced this whole mechanism: on 2026-08-08 the fleet was RPD-starved
with a balance the operator had just topped up, and the directive was *OR-capacity-dead ⇒ degrade*,
not *credit-dead ⇒ degrade*. The hard-402 and cross-model-429 legs reached only authoritative
stacks via trigger 1 — and every stack that dispatches on OpenRouter today runs shadow. Between 2
and 3: `.down` is an account-scope **verdict its owner already reached**, while the balance is an
**input** this launcher applies its own policy to, so the latch wins the trigger string
(`capacity:rpd` vs `credit:$0.17<$0.25` — same destination, different incident). It is one more
trigger on the existing path, not new policy: same `class=fix` bound, same `subscriptionFallback` /
`AGENT_SUBSCRIPTION_FALLBACK` opt-outs, same `modelDeny`, same FU-088(a) latch on the resulting ride.

⚠ **Key on the boolean `.down`, never on `.reason != null`.** The proxy evaluates the hold as it
serves (`"down": until > now`) but emits `reason` unconditionally, and only an early 2xx un-latch
clears it — so a healthy account that took one 429 last week still publishes `reason:"rpd"` beside
`down:false`. A reason-keyed read would degrade the fleet permanently from the first 429 it ever
takes. That server-side expiry is also why trigger 2 needs **no launcher-side freshness bound**:
there is no expired-but-set state to see, and `remaining_s` is a diagnostic, not an input. Both
reads come out of **one** payload — a second fetch could weigh a latch bit against a balance from a
different instant. Pinned by `agents/rail-degrade-replay.sh` (CAP…CAP6; CAP5 is the stale-`reason`
trap, CAP4 the lost-payload one).

Trigger 3 reads **`GET /router-status` → `.openrouter_capacity.credit_usd`** on the same
proxy — unauthenticated, ClusterIP-local, no credential of any shape. It used to call OpenRouter's
`GET /api/v1/credits` with the pod's opaque `ref:`, which is management-key-only and 403'd every
time, so the read was empty on every dispatch and **both** consumers were dead while looking healthy
(homelab#190; the proxy's own leg had the identical bug, homelab#180). The chain has one owner per
fact now: operator gauge → proxy → launcher. Two properties the launcher honours rather than
re-derives: the balance is `null` until the first usable poll, and the proxy **holds** its last
value across later poll failures — so freshness is judged by `.credit_age_s` against the proxy's own
`.credit_max_age_s`, and anything that is not a fresh number is *no balance*, never a low one.
An unavailable balance is **fail-open with one visible line** on the dispatch path naming the URL
(FU-104: the availability of a gate is worth less than the gate — but silent fail-open is what let
this rot). Since #194 that line also says **which** account-scope fact is missing: a payload that
never arrived (or has no capacity block) loses the latch bit *as well as* the balance and says so,
while a dead credit leg behind a live payload loses only the balance. Reporting "no balance" for
both would be #190's silence one level up — the operator would go look at the wrong leg. Pinned by
`agents/rail-degrade-replay.sh` (FAILOPEN…FAILOPEN4/STALE/CAP3/CAP4).

Degrading means `claude/haiku` on the subscription (`AGENT_SUBSCRIPTION_FALLBACK_MODEL` overrides).
It is a constant, not a search: harness, env card, credential shape and capacity gate all follow
from the model id through the one parser (§FU-127, `model_id.py`).

**Bounds** — the reason this is not a hole in the safety net:

1. **class=fix only.** A tasked `issue-*` ride. Research/adhoc rides keep deferring.
2. **Semaphore-bounded.** The degraded ride *is* a claude ride, so the FU-088 latch / utilization
   threshold / concurrency semaphore gate it unchanged — the reviewer and coordinator keep their
   slots, and with the subscription also limited the ride defers exactly as before. The existing
   capacity gate IS the protection; nothing new was needed.
3. **Per-stack opt-out.** `subscriptionFallback: false` on the stack row for a stack that should
   strictly wait; `AGENT_SUBSCRIPTION_FALLBACK=0` per run. ⚠ Read with `== false`, never
   `// false` — jq's `//` fires on `false` as well as `null`, which silently disables the knob
   (found by the replay, not by review). The claim's **`modelDeny` binds too**: a degrade is still
   a model choice, and an outage is not licence to hand a stack a model it has refused.

**Cost visibility.** A degraded ride carries `rail=subscription-fallback` on three surfaces: the pod
label `homelab.teststuff.net/rail` (live and queryable now — the semaphore's own selector is
untouched, since the pod draws exactly the capacity any claude ride does), the `AGENT_RAIL` pod env,
and the launcher's `POST /report` field. The last two are **declared, not yet consumed**:
`run_reports` has no `rail` column and `agent-finalize` does not fold `AGENT_RAIL` into
`AGENT_RUN_STATS` — until those land (router.py; the agent-runtime repo) the label and the launcher
log are what answer "what did the outage cost us".

⚠ **A claudeTier claim never needed any of this** — its rides ride the subscription already. Its bug
was the mirror image and is fixed as leg 1: a `claude/*` dispatch sends **no `key_ref`** to `/route`
and probes no OpenRouter state at all, and the rule that a failed/deferred key mint must not defer a
claude-tier dispatch is written down in the coordinator **brief** — the `RAIL —` note at the head of
the per-issue runbook in
[`../../agents/coordinator/README.md`](../../agents/coordinator/README.md), which also scopes its
estimate/mint steps to OpenRouter-primary chains — as well as in the per-dispatch **item prompt**
(the brief is the durable carrier; the item prompt is transient). The OpenRouter key is that ride's
*fallback* rail; treating it as a prerequisite is what deferred four dispatches into an idle
subscription. Mint failures are also the one leg with no proxy signal — the provisioning API is the
openrouter-operator's surface, not this proxy's — which is why leg 1 is an invariant rather than
another detector.

### M13. Research routing — deterministic slot draws on curated class pools (ADR-104, 2026-08-10)

The research process ([`research-and-specs.md`](research-and-specs.md)) selects models unlike any
lane above: it needs **N diverse models, not the best one**, and the experiment must be
**reproducible** — the jitter band is exploration budget for high-volume dispatch and corruption
inside a ~13-call mission. The contract is deliberately minimal (the mission-aware alternative —
step/roster/exclude semantics server-side — was rejected: it leaks roles.md process internals
into the mechanism layer):

- `/route` consumes three more fields: **`class`** (already in the schema — selects the curated
  pool), **`slot`** (1-based index into that pool's deterministic ranking), **`jitter: false`**
  (no jitter-band sampling; ties break stably). The response names the **pool version**. Same
  `(class, slot, jitter:false, pool-version)` → same model: idempotent, so a dead arm relaunches
  identically and the mission's roster is reproducible from its calls.
  ✅ **BUILT** (homelab#290, 2026-08-11). The draw is a pure lookup into the band
  (`router.draw_slot`) whose result then rides the ORDINARY filters as a one-entry chain — so a
  drawn-but-unusable slot answers with its usual typed defer (cooldown, capacity, deny) carrying
  `pool`/`pool_version`/`slot`, and never slides to the next model down. That last property is
  the one worth stating twice: the caller walks to `slot=N+1` itself, in the open, where the arm
  table records it. `jitter: false` zeroes the band *and* replaces the uniform pick with a stable
  tie-break, on the served decision and the §M11 shadow ladder alike. Response also echoes
  `jitter`, and the proxy log carries `draw=<pool>#<slot>@<version>`.
- **Pools are curated, never computed at request time** (§M7 leg 5, scout duty): ranked,
  family-deduped, **disjoint bands by convention** — `regular` authors, `premium` judges,
  `ultra` weaves, `instrument` for fixed-model probes. Disjointness is curation policy, NOT a
  router invariant: research is an operator-driven lane where visibility (the arm table,
  provenance chips) is the guard; enforcement machinery belongs to autonomous lanes. Which band
  a *process step* uses is process policy — the step ladder table lives in
  [`research-and-specs.md`](research-and-specs.md), not here.
  ✅ **SEEDED BY HAND** (homelab#290): `pools` in `model-classes.json` (`version` + four bands,
  one class per band). Curation policy is unenforced *at request time* exactly as ruled — the
  enforcement point is **edit time**: `devbox run router-self-test` refuses a table whose bands
  overlap, whose entries are outside `model_tiers` (the human-approved universe — no invented
  ids), whose band repeats a vendor family, or whose model rides a rail its class does not list.
  Two known depth shortfalls, both the scout refresh's job and neither a mechanism gap:
  `regular` is 6 deep against the doc's 7-arm over-provision (a 7-arm ask defers at slot 7
  today, visibly), and `instrument` shares the deepseek *family* with `regular`'s #2 — the run-1
  hazard was the same *model* grading its own arm, which disjointness already forbids.
- **No failure semantics beyond what /route already has.** A dead arm waits, relaunches, or
  takes `slot=N+1`; the caller over-provisions (ask for 7, need 5) and the pool ranks deeper
  than any plausible ask. Cooldown/capacity answer as today — a typed defer may pause an
  experiment, never silently rewrite its design.
- Callers name **zero models**. First consumer: `agents/research-fanout.sh` — ✅ **CONVERTED**
  (homelab#290): `--arms N [--class regular] [--dry-run]`, one `/route` draw per slot, hand-picked
  model ids refused by name rather than mis-parsed. Deferred slots stay empty in the arm table
  with their reason; the roster + pool version print before any dispatch, and `--dry-run` stops
  there. Pinned by `agents/replay/fixtures/research-draw-roster` (recorded from `router.route()`
  against the shipped pool table). Build: FU-162.

### M14. Provider selection — priced per successful JOB (ADR-115, 2026-08-26)

**The decision record is ADR-115; this section owns the mechanism.** Born from the 0731 intake
read (TICK-LOG 2026-08-26; digest homelab#966): the M4 pin optimizes effective $/M with an
uptime floor and is blind to serving QUALITY — measured on one model, provider tool-call error
rates span 0.2%→39.6% (single-snapshot, across providers; one provider's DAILY series ranges
wider — DigitalOcean 29–56% over the probed window, the Evidence base below) and GPQA 68.7→90.0
(quantization + serving stack, not weights), our pin
sampled the mid/bottom of that distribution exclusively, and uptime cannot see the failure class
(a malformed tool call arrives inside a 200). The missing term is **overhead cost**:

    expected_cost(provider) = eff_price × expected_tokens
                            + p(fail | provider, model) × C_overhead

`C_overhead` = the measured downstream cost of a failed ride (strike handling + re-dispatch +
coordinator session + review rounds + wall clock; ~$0.5–2 plus latency, from our own ledger).
At flash prices the failure term dominates any price delta (→ delegate); at research prices the
price term re-enters (→ our pin, upgraded). One formula, two regimes.

**Class policy (`provider_policy` in model-classes.json — git-side, per the git/cluster split):**

| class tier | policy | mechanism |
|---|---|---|
| cheap coding (`coding` on flash-class models) | **`exacto`** — no `provider.order` injected; Auto Exacto (ON by default upstream for tool requests) owns the ordering; keep only `max_price` | subtractive: the pin injection is skipped; the FU-088/M12 gates, `MAX_TOKENS_FLOOR`, and the `/generation` harvest (attribution) are unchanged |
| priced (research / audit / weave / judges) | **`pin-v2`** | M4 + (1) the 15% band with a serving-quality tie-break inside it (native/fp8 over fp4 → per-provider Exacto benchmark score → market cache-hit); (2) a permissive benchmark provider-floor (drop only KNOWN scores ≫ below the model's provider median; slug-keyed join — display names differ); (3) a live tool-call-error floor from the `stats/tool-call-error-rate` feed (exclude ≥10% 5d-avg; de-prefer >2× model median in-band); (4) (model, provider) pair-cooldowns fed by the proxy's own tool-call validation — the #783 provider-attribution legs |
| experiments (scout matrix / canary arms) | **explicit `@` arms** (PR#963): `@<provider_slot>` (eff-ranked index, typed 400 when unresolvable) or `@<slug>`, `allow_fallbacks: false`; `:exacto` forwards un-pinned | the reproducibility instrument — never the production policy |

**⚠ Exacto ↔ prompt caching (operator find, 2026-08-26 — upstream
[docs/guides/routing/auto-exacto](https://openrouter.ai/docs/guides/routing/auto-exacto)):**
Auto Exacto reorders providers on EVERY tool-calling request, overriding the sticky routing
prompt caching rides — in a tool loop it can deprioritize the cache-warm provider mid-session
(upstream's own words: cache misses mid-conversation). That collides head-on with M4's doctrine
(cache lives AT the provider; caching provider > cheaper provider) and with this fleet's
cacheRead-dominated token shape. Consequences, folded into the build order: the step-1 flip is
judged on OBSERVED per-arm cache-hit (`router_observed_cache_hit` + the `/generation` harvest),
never price+tool-error alone — at flash prices the failure term may still dominate the cache
penalty, but that is the A/B's question, not an assumption. If Exacto loses on cache economics,
the opt-out shapes are `sort: "price"` in the provider object or the `:floor` variant (both keep
sticky routing, both subtractive like the pin-skip), or Tool Search `defer_loading: true` to
shrink the cached prefix until an Exacto collision is tolerable. The priced classes are
unaffected — pin-v2 keeps the session pin, which is itself the cache-stickiness mechanism.

**The scout representativeness principle:** a canary rides the provider policy of the CLASS it
feeds — same policy, not same provider (an Exacto-routed class gets Exacto-routed canaries;
pinning them would make the evidence LESS representative). Newcomer cold-start (Exacto has no
history on a new model → early ordering ≈ uninformed) is absorbed by the existing attempts
budget + the served-slug harvest; provider DIAGNOSIS stays the `@`-arm matrix's job. Follow-up:
canary rows should carry the SERVED slug from the harvest, not `provider:""`.

**Evidence base (2026-08-26, all live-probed):** the pin picked Relace fp4 over DeepSeek
first-party (native, top GPQA/TAU, 95% market cache, 100% uptime) for $0.0012/M; DigitalOcean
pin-eligible at 29–56% tool-error (per-endpoint DAILY series from the found
`stats/tool-call-error-rate` endpoint — a multi-day range, which is why it exceeds the
single-snapshot spread's 39.6% max); our 0731 traffic = Relace/OpenInference/DeepInfra only,
strikes un-attributable (#783); the elite tool-call tier (Fireworks 0.23%) never sampled, ~3×
price ≈ cents/month at fleet volume. Rung-1 canaries pass on BOTTOM-quartile providers
(homelab#966: both harnesses clean via OpenInference/Relace), so the discriminating evidence
needs rung-2-size tasks × provider arms.

**Build order (fresh-session pickup — FU-186):**

1. **Exacto flip for cheap coding** — `provider_policy` knob in model-classes.json + the proxy
   skipping pin injection for that policy (keep `max_price`); trial-gated: the matrix A/B below
   judges it before it becomes standing.
2. **The 0731 matrix run** (the re-admission evidence): intake mode (built) ×
   `SCOUT_CANARY_HARNESSES="opencode goose"` × arms {default-pin, no-pin/exacto, `@deepseek`,
   `@relace` control} on a rung-2-sized task (the trivial ride does not reproduce the failure
   class), judged on death rate / $/clean / cache-hit from the harvest. Verdict lands as the
   model_tiers re-admission PR citing the digest chain.
3. **pin-v2** for the priced classes (the four legs above; the tie-break is `compute_pin`'s
   `ranked` sort key growing quality terms — the plumbing shipped in PR#963).
4. **The proxy tool-call validator** → `router_tool_call_errors{model, provider}` (our-traffic
   twin of the upstream feed) + pair-cooldowns + the model-health dashboard column + an
   alert on our traffic landing on a high-error serving.

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

