# Model routing — chains, strikes, and a live registry (not one hardcoded model)

> **Status: direction set 2026-07-09; core BUILT same week** — the live registry is code
> (`estimate_budget.py`: cached /models + /endpoints, cache-aware effective price, `--lookup`),
> strike bookkeeping is in the launcher (`AGENT_STRIKE` comments), goose provider injection is LIVE
> via the egress proxy, opencode carries the per-session pin, and the model scout v1 is deployed
> **suspended** (first supervised run = the remaining tail, with FU-024's live-fire canary).
> Born from the oracle-fleet issue #1 postmortem + the 2026-06-29 qwen cost autopsy. This doc is
> the umbrella for **FU-062** and binds together FU-018 (provider injection), FU-021 (retry
> hard-stop — resolved), FU-024 (only-free guardrail) and FU-057 (ledger/error-class — live)
> — they only work as one design. Companions: [`observability-and-retro.md`](observability-and-retro.md)
> (the ledger this feeds), [`../../agents/coordinator/README.md`](../../agents/coordinator/README.md)
> (the brief that executes it).

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

Maps 1:1 onto the FU-057 `error_class` (already planned for AGENT_RUN_STATS):

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

**Until the registry is code**, the estimator's `--price-per-mtok` override already unblocks any
model today: fetch the price live and pass it (the brief carries the recipe). A `$1.0/M` default in
the verdict means "unpriced", not "forbidden".

### M4. Provider pinning per session (the FU-018 leg)

Cache lives *at the provider*, so per-request routing that bounces providers destroys it — pinning
must be per **session**: the dispatch picks the effective-cheapest cached provider (M3 data, with an
uptime floor — Google Vertex at 37% uptime is a trap) and pins `provider: {order:[...],
allow_fallbacks: true, max_price: {...}}`. Ranked levers from the autopsy stand: **caching provider >
cheaper provider > fewer requests**. Where to inject (unchanged from FU-018, now load-bearing):
opencode = `opencode.json` `options.provider` (works today); **goose cannot carry provider prefs** →
the ADR-081 egress proxy rewriting the request body is the universal home (**v1 LIVE 2026-07-09**,
provider-injection only: `argocd/resources/openrouter-proxy/`, wired as goose's `OPENROUTER_HOST`;
creds + Cilium stay FU-018/FU-020). ⚠ Measured: `provider.order` matches the endpoint **tag's base
slug** (`atlas-cloud`, `deepinfra`) — display names (`AtlasCloud`) silently no-op. Free models sidestep M4
entirely ($0 either way) — one more reason they front the chains for small tasks.

### M5. Attribution (the FU-057 tie-in)

Dynamic routing without attribution would blind the very ledger that makes blacklist calls. Per run,
AGENT_RUN_STATS/manifest/ledger must record: requested model, **served model** (router runs resolve
to a real model), **served provider**, measured **cache-hit %**, `error_class`, strike count. Source:
the OpenRouter activity/generation API (already in FU-057's scope for per-request splits). Worker
`cost_usd` → Prometheus stays as planned.

### M6. Routers — verdict (verified against the API 2026-07-09)

- **`openrouter/pareto-code`**, `fusion`, `bodybuilder`: do **not** advertise `tools` → presumed
  unable to drive a goose/opencode worker. One manual probe to confirm the metadata, then park.
- **`openrouter/auto`**: advertises tools, but it's a paid model lottery — you cede provider AND
  model choice, i.e. the $5.79 incident as policy. Last chain slot at most, cap-bounded.
- **`openrouter/free`**: a **free router with tools** — the provider/price lottery is harmless at $0,
  and it dodges "this free model vanished today" faster than our ledger can. Strong scout/chain
  candidate for xs/sm tasks.

### M7. The model scout (new, small)

A weekly reflex (Argo CronWorkflow sibling of review-reflex, per ADR-093 — the loop reflexes moved
k8s CronJob → Argo CronWorkflow): diff `/models` against the known set; filter
tools-capable + (free or ≤ price ceiling); run each newcomer on a **canary task** (a small, closed,
known-good issue — same pattern as the oracle free-tier canary); write the outcome to the ledger.
Newcomers graduate into chains with evidence, not vibes. Free scout keys want **FU-024**
(`guardrail: only-free` actually enforced) so a scout key can't spend.

## The bundle — why these FUs resolve together

| FU | role in this design | without it |
|---|---|---|
| **FU-062** (this doc) | strikes vs rounds, chains, registry, scout | the single-model lock stands |
| **FU-057** | `error_class` + served model/provider/cache-hit in the ledger | strikes unclassifiable, blacklists blind |
| **FU-018** | provider pinning injection (opencode now, proxy for goose) | effective price unenforceable → $5.79 repeats (cap-bounded) |
| **FU-021** | goose hard-stop on auth/limit errors | a strike burns its whole session cap in a retry storm first |
| **FU-024** | enforced only-free guardrail | scout/free keys are honor-system |

## Do today (before the next coordinator session)

1. ✅ Brief: `MODEL` block → chain + strike policy (`agents/coordinator/README.md`).
2. ✅ `stacks.json`: `workerModelFallbacks` per stack (oracle leads with `tencent/hy3:free`).
3. ✅ Estimator: price `tencent/hy3` (+`:free`) in the table; comment corrected (free-tier claim
   dated, override recipe). Full live registry = the code follow-up.
4. Oracle #1: close PR #5 (Node scaffold, superseded by the language decision — see oracle-fleet /
   the teststuff architecture doc: chassis = **Python**), re-queue with the issue re-scoped to the
   Python scaffold. The re-run doubles as the first live test of the chain policy.

The truncation postmortem and the language call reinforce each other: the cheap-model lane is
measurably weakest exactly where the Node scaffold stressed it, the entire proven loop
(sleep-tracking: fixer→reviewer→renovate→deploy) runs on a Python/uv repo, and nothing
Node has merged to oracle-fleet master — the flip is free today and compounds later.
