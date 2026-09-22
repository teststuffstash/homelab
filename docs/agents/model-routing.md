# Model routing — the ladder, the strikes, and the carriers (rules only)

**This doc owns model choice.** Every rule below carries either an **anchor** — the `file:function`
that enforces it — together with the **evidence query** that shows it firing (a Prometheus
expression, a `/router-status` field, or a replay fixture name), or an explicit **`unenforced`**
mark naming the child that owns landing it. The investigations these rules grew out of
(§M1–§M14) moved on 2026-09-17 to
[`../spikes/model-routing-history.md`](../spikes/model-routing-history.md), where the `§M*` codes
still resolve — this doc **links** that archaeology rather than restating it (ADR-117/CLAUDE.md
"link, don't restate"). `§M*` codes are stable: never renumbered, never reused.

**Where the machinery lives.** `argocd/resources/openrouter-proxy/router.py` is the decision core
(`/route`, the strike store, the cooldowns, `/router-status`, the metric family);
`argocd/resources/openrouter-proxy/openrouter-proxy.py` is the request plane (the provider pin,
the capacity gates, `:exacto` handling, credential injection);
`argocd/resources/openrouter-proxy/model-classes.json` is the git-owned **POLICY** half (classes,
rails, floors, pools, cooldown durations) — policy in git, live state in the store. The pricing
registry is `agents/estimate_budget.py` (cached `/models` + `/endpoints`, market effective price,
`--lookup`). Companions: [`observability-and-retro.md`](observability-and-retro.md) (the ledger
this feeds) and [`../../agents/coordinator/README.md`](../../agents/coordinator/README.md) (the
brief that executes it).

> **One status line that is not a rule.** The `provider_policy: exacto` rule below is *enforced*
> in code; its STANDING is a live trial judged by Goal #1640 acceptance 8 (PR#1639's flip re-read
> against ≥1 week of `router_tool_call_errors`/strike rows). Enforced, not yet permanent.

## The design's three rules

1. **Rounds ≠ strikes.** A *logic* failure (a reviewer's `CHANGES_REQUESTED`, CI red on the
   change) is a ROUND — capped, then escalated to a human. An *infra* failure (harness death,
   auth storm, timeout, provider 5xx, a cap death) is a STRIKE — it consumes no round, excludes
   the struck cell for that task, and re-dispatches.
   - anchor: `agents/review-reflex.sh` (`ROUNDS_MAX`, the review verdict cap) and
     `agents/coordinator-scan.sh` (`RED_ROUNDS_MAX`, the CI-red fix-round cap); the strike side is
     `router.py:record_report` + `router.py:route`.
   - evidence: the issue's labels/round comments; `router_strikes_total{error_class=…}`.
2. **Blacklists are scoped; only the ledger blacklists globally.** A strike is per
   `(task, model, provider)`; the global call comes from the FU-057 model-health pivot over
   evidence across tasks.
   - anchor: `router.py:strikes_for` (`WHERE task=? AND stack=?`) and
     `router.py:route` (the exclusion set).
   - evidence: `/router-status` → `strikes_7d`; the decision row's `skipped[]`.
3. **Caps bound the tail.** A failed model attempt costs a re-dispatch, never a round, which is
   what makes trying a `:free`/new/pinned-provider cell rational; the per-session budget key stays
   the hard guardrail.
   - anchor: `agents/estimate_budget.py` (the `budgetUSD` key) and the FU-088 gates in
     `openrouter-proxy.py`.
   - evidence: `router_run_reports_by_rail_total{rail=…}`; `/router-status` → `decisions_24h`.

## The ladder — rail → class → tier → cell

One `/route` call walks four rungs, in this order. `router.py:route` is the walk; the rung's rule,
its anchor and its evidence:

| rung | what it decides | anchor | evidence |
|---|---|---|---|
| **rail** | which billing rails are candidates at all | `model-classes.json` → `classes.<cls>.rails`, read at `router.py:route` | decision row `rail`; `/router-status` → `decisions_24h[].rail`, `router_run_reports_by_rail_total{rail=…}` |
| **class** | which `classes` row applies | `router.py:route` (`label_map` → `role_defaults`) | decision row `class`; replay `agents/replay/fixtures/route-request-labels` (the caller's assembled body) |
| **tier** | the class tier + the label-merged floor | `router.py:route` (+ `router.py:_TIER_ORDER`) | decision row `tier`, `skipped[]` reasons `tier-floor:*` / `never-free:*` |
| **cell** | the `(model × provider)` that is priced and pinned | `router.py:route` (`ctx["price"](m, exclude)`) + `openrouter-proxy.py:pin_for` | decision row `provider` / `price_per_mtok`; `router_generation_cost_usd_total{model,provider}` |

### Rail rules

- **A class names its rails.** `classes.<cls>.rails` (default `["openrouter","subscription"]`);
  a candidate's rail is derived from its id (`claude/*` → `subscription`, else `openrouter`), and a
  candidate whose rail the class does not list is skipped.
  - anchor: `router.py:route`; `model-classes.json` → `classes`.
  - evidence: decision row `skipped[{reason: "rail-<rail>-not-in-class-<cls>"}]`; `devbox run
    router-self-test` (the eligibility rows).
- **Rails are walked in class order; the first rail with an eligible, priced candidate wins.**
  - anchor: `router.py:route` (the `for rail in rails` walk).
  - evidence: decision row `rail` + `jitter_pool`; `/router-status` → `decisions_24h`.
- **Each rail has a capacity gate; a gate that closes refuses the whole rail with a typed defer —
  it never falls through to a cheaper-but-unwired model.** The subscription gate is the FU-088
  latch/utilization/semaphore triple; the OpenRouter gate is the key/credit state.
  - anchor: `router.py:route` (`sub_gate`/`or_gate`, memoized to at most one read each) and the
    capacity state in `openrouter-proxy.py`.
  - evidence: `router_decisions_total{decision="defer",reason=…}`; replay
    `agents/replay/fixtures/fu088-ladder`.
- **A chainless stack draws from the rotation universe** — `model_tiers` keys ordered by the
  class's `chain_head` first, then the ranked rotation — and the launcher refuses a chainless
  dispatch that has no authoritative routed verdict.
  - anchor: `router.py:_rotation_candidates`; `agents/agent-session.sh` (the chainless refusal).
  - evidence: decision row `source="rotation"`; [`chainless-redesign.md`](chainless-redesign.md).
- **The across-rails cost ladder (free → subscription → paid) is MEASURED IN SHADOW ONLY.** The
  served walk is byte-for-byte the pre-ladder one; the ladder rides along in `decision.shadow`.
  - anchor: `router.py:_shadow_ladder`, written by `router.py:record_shadow_decision`.
  - evidence: `/router-status` → `ladder_cells`, `shadow_24h`; `router_shadow_decisions_total{agrees="0"}`
    (the divergence the soak reviews), `router_shadow_start_tier`.
  - **`unenforced`** for the *served* pick — the P4 flip discipline owns it, and the owning
    concern is NAMED: FU-095, whose recorded next step is the flip child — "the ladder promotion
    into the served path" ([`../follow-ups.md`](../follow-ups.md)). No child minted yet.

### Class rules

- **Class assignment is a deterministic lookup, never inference (ADR-094).** Explicit `class` →
  `label_map[label]` → `role_defaults[role]` → `coding`. It happens at authoring/scan time; the
  data plane never infers difficulty per prompt.
  - anchor: `router.py:route`; `model-classes.json` → `label_map`, `role_defaults`.
  - evidence: decision row `class`; replay `agents/replay/fixtures/route-request-labels` (the
    labels the launcher actually sends).
- **All matching labels merge; the first match does not win alone.** `tier_floor`/`never_free`
  accumulate across every label present (a non-budget label may sort first and carry no tier keys).
  - anchor: `router.py:route` (the `for lab in labels` merge).
  - evidence: decision row `skipped[{reason: "tier-floor:…" | "never-free:label_map"}]`; the
    `#1259` self-test rows.
- **Tier comes from the class unless the dispatch overrides it**: `payload.tier` >
  `classes.<cls>.tier` > `heavy`. A `tier_floor` excludes any model graded below it in
  `model_tiers`.
  - anchor: `router.py:route` + `router.py:_TIER_ORDER`.
  - evidence: decision row `tier`; `devbox run router-self-test` (the #1259 tier rows).
- **Per-stack deny is composed into the filter** (`modelDeny` on the claim, launcher-side).
  - anchor: `router.py:route` (`claim-deny`); `agents/stacks.json` mirrors the claim.
  - evidence: decision row `skipped[{reason: "claim-deny"}]`.
- **Per-class capability floors are permissive on missing data** — a model with no capability row
  always passes, so a data gap can never brick a chain.
  - anchor: `router.py:capability_floor_block`; floors in `model-classes.json` → `class_floors`.
  - evidence: decision row `skipped[{reason: "capability-floor:<what>"}]`; `devbox run
    router-self-test` (the precedence rows).
- **Family decorrelation is a `/route` primitive** (`decorrelate_from` → the author's VENDOR
  family is excluded, rail-agnostic); an emptied set defers typed instead of degrading to a
  same-family pick.
  - anchor: `router.py:route` + `router.py:vendor_family`.
  - evidence: decision row `skipped[{reason: "decorrelate:<family>"}]`; `devbox run
    router-self-test` (the decorrelate rows); replay
    `agents/replay/fixtures/decorrelate-resolution` (the caller side that supplies it).
- **A slot draw is a pure pool lookup that then rides the ORDINARY filters as a one-entry chain**
  — a drawn-but-unusable slot answers with its usual typed defer and never slides to the next
  model; the caller walks to `slot=N+1` in the open.
  - anchor: `router.py:draw_slot`; pools in `model-classes.json` → `pools` (`version` + bands).
  - evidence: `/route` response fields `pool`/`pool_version`; replay
    `agents/replay/fixtures/research-draw-roster`.

### Cell rules (price + pin)

- **A candidate is priced by the provider it will actually land on AFTER the task's exclusions**
  (the next cheapest CELL), never by the model's default provider; a model whose every provider is
  excluded drops out.
  - anchor: `router.py:route` (`ctx["price"](m, _ex)`).
  - evidence: decision row `price_per_mtok` + `provider`; `devbox run router-self-test` (the
    post-exclusion re-pricing rows).
- **The pin's `max_price` is bounded by `MAX_PRICE_FACTOR` (2.0) over the pinned provider's price**
  — the guard against the fallback lottery, not a preference.
  - anchor: `openrouter-proxy.py:MAX_PRICE_FACTOR` and `openrouter-proxy.py:compute_pin`.
  - evidence: `router_generation_cost_usd_total{model,provider}` (billed, post-hoc) vs the pinned
    price in the decision row.
- **Among same-rail candidates the effective-cheapest wins, with a uniform pick inside a 15%
  jitter band** (`selection.jitter_band_pct`) — the exploration budget that keeps cell evidence
  accruing. `jitter: false` zeroes the band and replaces the uniform pick with a stable tie-break.
  - anchor: `router.py:route` (`jitter`, `pick_fn`); `model-classes.json` → `selection`.
  - evidence: decision row `jitter` + `jitter_pool`; replay
    `agents/replay/fixtures/research-draw-roster`.
- **The provider pin is injected per `(session, model)`** — cache lives at the provider, so a
  per-request bounce destroys it. `provider.order` matches the endpoint tag's BASE slug (a display
  name silently no-ops) and carries an uptime floor. The cache is swept and hard-capped at
  `PIN_CACHE_MAX`.
  - anchor: `openrouter-proxy.py:pin_for` (+ `compute_pin`, `PIN_CACHE_MAX`).
  - evidence: `devbox run proxy-self-test` (the pin-key + `PIN_CACHE_MAX` sweep rows);
    `router_observed_cache_hit{model}`; `/router-status` →
    `generations_24h[].observed_cache_hit`.
- **`:free` models sidestep the pin** (`$0` either way) — one more reason they front the chains for
  small tasks.
  - anchor: `openrouter-proxy.py:pin_for` (returns `None` for a free model).
  - evidence: decision row `provider: null` on a free pick.
- **`provider_policy: exacto` (the cheap coding class) is SUBTRACTIVE**: the pin injection is
  skipped, only `max_price` is kept, and the `:exacto` suffix is appended **idempotently** — only
  for a paid OpenRouter pick (`:free`, `opencode-go/`, `openrouter/`, subscription picks and an id
  already carrying the suffix are left alone).
  - anchor: `router.py:route` (the `provider_policy` branch); `model-classes.json` →
    `classes.coding.provider_policy`; `openrouter-proxy.py` (the `exacto_no_pin` skip).
  - evidence: decision row `provider_policy` + the served id's `:exacto` suffix; the `#1693`
    idempotence self-test row.
- **The priced classes keep the pin** (`pin-v2` direction: quality tie-break inside the band, a
  permissive benchmark provider-floor, a live tool-call-error floor).
  - **`unenforced`** — the legs are recorded on the Goal as Goal #1640 acceptance 8's evidence
    base; the tie-break plumbing shipped in PR#963 (`compute_pin`'s `ranked` sort key).
- **Serve a canary under the CLASS's policy, not the same provider** (an Exacto-routed class gets
  Exacto-routed canaries) — pinning a probe would make its evidence less representative.
  - **`unenforced`** — a recorded principle of the provider work; the scout's arm list exists
    (`agents/model-scout.sh` `CELL_PROVIDERS`: `""` = the proxy's own pin, an integer slot, or a
    slug) but nothing asserts the class-policy equivalence. Owner: Goal #1640 acceptance 8's
    matrix run (its arms are the evidence), and the follow-up that canary rows carry the SERVED
    slug.
- **Latency is an ordering dimension, tie-broken on measured decode tokens/sec per
  `(model, provider)` inside the band** — never the model page's advertised percentiles.
  - anchor (the harvest half — LANDED, homelab#22): `router.py:record_generation` (the
    `generations.generation_ms` column) exported by `router.py:metrics_lines`.
  - evidence: `router_observed_decode_tps{model=…}`.
  - **`unenforced`** for the ORDERING half — nothing reads the series: `model-classes.json` →
    `selection.rule` is `cheapest-effective-jitter` (price only) and no pin or route sort key
    consults decode tokens/sec. **Proposed, no owner.**

## The strike ladder

**The vocabulary is ONE set, and the router serves it so no consumer keeps a drifting copy.**
`STRIKE_CLASSES` is the set; `SERVING_CLASSES` is a SUBSET VIEW of it (the self-test pins
`SERVING_CLASSES <= STRIKE_CLASSES`), and the subset — not a second list — decides pair-vs-model
scope.

| class | scope | what it means |
|---|---|---|
| `harness-death` | model | the harness died (goose `-32602` and kin) |
| `auth-storm` | **pair** | 401/403 storm from the serving provider |
| `timeout` | **pair** | the completion timed out at the provider |
| `provider-5xx` | **pair** | provider 4xx/5xx response |
| `no-pr` | model | the ride produced no artifact |
| `unknown` | model | unclassified death — the FU-200 reader's latch class |
| `turn-cap` | model | a goose ride that died at the turn cap (homelab#1665) |
| `tool-loop` | **pair** | a cap death with zero tool-result progress — the same tool call repeated (homelab#1665); a SERVING shape, not a model verdict |

- anchor: `argocd/resources/openrouter-proxy/router.py:STRIKE_CLASSES` and
  `router.py:SERVING_CLASSES` (the vocabulary's one home).
- evidence: `/router-status` → `strike_classes` / `serving_classes`;
  `router_strikes_total{error_class=…}`.

**Strike rules**

- **Recording matches EITHER `outcome` or `error_class`; the row STORES a vocabulary member.**
  The launcher sends the coarse class in `outcome` and a fine sub-type in `error_class`; a
  predicate testing one field recorded almost nothing (the §M1a drift). The write side is the
  same rule's other half, landed 2026-09-17: the strike row's `error_class` holds the MEMBER
  (`err` if it is one, else `outcome`, else `unknown`) and the fine sub-type is kept beside it in
  `error_subclass` as evidence. Measured before the fix, on the live store: 31 strikes ever, **0
  in `SERVING_CLASSES`**, 24 outside `STRIKE_CLASSES` — so `pair_cooldowns` (which filters
  `error_class IN SERVING_CLASSES`) was empty by construction, and every serving failure fell to
  model-scope. A reader tests the field the writer fills, or the vocabulary is decoration.
  - anchor: `router.py:record_report` (the `_klass`/`_subclass` resolution).
  - evidence: the self-test's producer-shape row + the "no non-vocabulary strike series" metric
    guard; `/router-status` → `strikes_7d[].subclasses`.
- **Pair scope is EARNED by knowing the provider; absent it, model scope stands.** The exclusion
  loop tests `error_class IN SERVING_CLASSES **and** provider != ''` — a serving strike whose
  provider is unknown excludes the MODEL, exactly as it did before the vocabulary was enforced.
  Without this the write-side fix would have un-excluded live cells the day it landed
  (`served_provider` was empty on all 42 rides in the 2026-09-17 window).
  - anchor: `router.py:route` (the `_strike_rows` loop).
  - evidence: the self-test's providerless-serving-strike row.
- **A strike is per `(task, model, provider)` and lives in the router's `strikes` table**; the
  `AGENT_STRIKE:` comment is its audit twin.
  - anchor: `router.py:record_report`; `agents/agent-session.sh` (the comment).
  - evidence: `/router-status` → `strikes_7d`; replay
    `agents/replay/fixtures/router-report-strike-by-pod`.
- **Enforcement is unconditional and per task** (the strike-enforcement env knob was retired and
  then DELETED — homelab#1666 / PR#1685): a serving-shaped strike excludes the `(model, provider)`
  PAIR and re-prices the model at its next provider; a model struck at ≥2 providers is excluded at
  MODEL level (the #783 rule); every other class excludes the model on one strike.
  - anchor: `router.py:route` (`strikes_for` → `struck_pairs`/`struck_models`).
  - evidence: decision row `skipped[{model, provider, reason: "strike"}]` + `strike_excluded`;
    `devbox run router-self-test` (the four acceptance-3 rows); replay
    `agents/replay/fixtures/router-report-strike-by-pod`.
- **The escalation is `agent/blocked`/arbitrate only where a human decision is genuinely needed**
  — chain exhausted with the strike list, or the round cap reached.
  - anchor: `agents/coordinator-scan.sh`, `agents/review-reflex.sh`.
  - evidence: the `AGENT_STRIKE:` comment listing the chain; the issue's lifecycle labels.
- **A key-class budget error is NOT a strike.** `budget-403-key` / `budget-exhausted-key` are a
  mint defect → a `KEY-RETRY:` marker, same model, fresh session key.
  - anchor: `agents/agent-session.sh` (the `KEY-RETRY` branch).
  - evidence: the `KEY-RETRY:` comment; `devbox run clause-replay` over
    `agents/replay/fixtures/strike-quota-classifier` (the classification it rides on).
- **The raw-log fallback emits the finer subclasses** when no structured report exists
  (`budget-403-key`, `budget-403-account`, `http-403-other`) — the residual `budget-403` is
  neither a strike nor a key-retry and escalates.
  - anchor: `agents/agent-session.sh` (the classify block).
  - evidence: replay `agents/replay/fixtures/strike-quota-classifier` (three branches); the
    comment's `error_class=`.
- **A clean ride refutes a counted pair strike** (`outcome='pr'` on the same model +
  served provider) — never a bare 2xx: a provider serving badly behind HTTP 200 is exactly the
  failure the pair cooldown exists to route around.
  - anchor: `router.py:pair_cooldowns` (the `clean` sub-query).
  - evidence: the pair-cooldown self-test's "a 2xx must NOT clear it" / "a clean ride clears it"
    rows.
- **The `(model, provider)` pair cooldown is a derived view over the `strikes` table** — no second
  table: trip at ≥2 DISTINCT tasks striking the pair with a serving class inside the window, hold
  6 h doubling per streak up to 7 d, half-open on expiry (one ride is the probe), and a strike
  during half-open doubles the hold.
  - anchor: `router.py:pair_cooldowns`; durations in `model-classes.json` → `cooldown`
    (`pair_window_s`/`pair_min_tasks`/`pair_base_s`/`pair_max_s`).
  - evidence: `router_cell_cooldown{model,provider}`; `/router-status` → `pair_cooldowns`;
    `devbox run router-self-test` (the trip/half-open/refute rows).
- **The transport belt is a SEPARATE, HTTP-fed cooldown keyed `(model, role)`** — passive provider
  events only (never upstream uptime), and ANY 2xx clears it. The two mechanisms are never
  conflated.
  - anchor: `router.py:cooldown_note`, `router.py:active_cooldowns`.
  - evidence: `router_cooldowns_active{role=…}`; `/router-status` → `cooldowns_active`;
    `router_provider_events_total{class=…}`.
- **`goose-32602-truncation` is a PER-CELL signal, never a fleet latch.** It is the producer's
  fine sub-type for a goose tool-call truncation (the class a cap death used to hide in); two
  sightings in 24 h on the SAME cell are one cell's problem, not a fleet event — unlike the
  `unknown` latch below, which is deliberately fleet-level until the vocabulary child lands.
  - **`unenforced`** — operator direction 2026-09-14: the class is no vocabulary member
    (`router.py:SERVING_CLASSES` carries no entry for it) and nothing counts sightings per cell —
    the launcher's `-32602` branch reports the COARSE class (`agents/agent-session.sh`,
    `ERR_CLASS=harness-death`), as does agent-finalize. **Proposed, no owner** (a Goal #1640
    follow-up; the interim `unknown` latch below still applies).
- **The producer-side half of the vocabulary lives in agent-runtime.** `agent-finalize` is the
  component that must report a member of `STRIKE_CLASSES`, and the storm watchdog must kill a
  block repetition (N consecutive identical tool calls with identical results, read from the goose
  session db) via the marker path so finalize classifies it. The router's side — the set, the
  `/router-status` export and the scope split — is the anchored half above.
  - **`unenforced`** — Goal #1640 acceptance 1 (the finalizer/watchdog half; the router half
    landed in PR#1734). Not verifiable from this repo.
- **The launcher retries at worker-terminal.** `AGENT_STRIKE` ∧ salvage verdict `none` ∧ class ∈
  {serving-shaped, `turn-cap`} ∧ attempts < cap (one automatic retry per
  `(model, provider, class)`, two per task) ⇒ `/route` again and re-run at the SAME round — no
  scan re-queue, no coordinator session; cap reached ⇒ the strike list + doorbell as today.
  - **`unenforced`** — Goal #1640 acceptance 4 owns it (the launcher-side retry ladder is not
    built).
- **The FU-200 fleet reader re-keys on `(class, provider)` / `(class, model)` / neither** — a
  repeated serving strike latches the PROVIDER (or nominates the MODEL for the ledger) instead of
  labelling issues; `agent/error` on issues stays for the "us" case only, and a clean retry
  refutes a counted strike.
  - anchor: `agents/coordinator-scan.sh` (the fleet reader — Goal #1640 acceptance 5, the reader
    half, landed via homelab#1781): the scan still counts the same `error_class` on ≥2 distinct
    issues inside 24 h, but it ASKS `/router-status` (`serving_classes`, `pair_cooldowns`,
    `generations_24h`) and keys the group — a cooled pair ⇒ provider latch (report only), a model
    struck across providers ⇒ ONE `model-nomination:` record issue, neither ⇒ `agent/error` +
    ONE `fleet-strike:` issue with a `fleet-strike-fp:` marker; an unreadable router status is
    fail-closed and loud.
  - evidence: replay `agents/replay/fixtures/fleet-reader-rekey` (the three branches, the clean-retry
    refutation, the unreadable router, the FU-202 key-class exclusion) +
    `agents/replay/fixtures/fleet-strike-reader` (the us-case ticks); the `fleet-strike:` /
    `model-nomination:` issue titles.
- **The strike comment remains the store FOR NOW, with a named debt**: migrate the strike READERS
  (the chain-walk, the ≥2-in-24h rule) to the router store's `strikes` table, then demote the
  comment to one appended line on the `agent-summary` index.
  - anchor: `agents/agent-session.sh` (the writer) + `agents/coordinator-scan.sh` (the reader).
  - evidence: replay `agents/replay/fixtures/fleet-strike-reader`.
  - **`unenforced`** for the migration — operator ruling 2026-08-19; blocked on the router's
    storage-engine question settling. Proposed, no owner.

## The carriers

**Rails** (`run_reports.rail`, four canonical values): `openrouter` (paid, key-gated),
`subscription` (the claude Max plan, FU-088-gated), `opencode-go` ([the Go rail](chainless-redesign.md)),
and `subscription-fallback` (the §M12 degrade). The folded accounting view is in
`agents/ledger.py:_model_rail()`.

- **OpenRouter capacity-down ≠ budget-spent.** A project-key headroom exhaustion stops the
  dispatch (a budget decision); an ACCOUNT-scope failure (credit floor, hard 402, cross-model 429s)
  degrades it to `claude/haiku` on the subscription instead — an infra failure, the same class as
  a 5xx.
  - anchor: `openrouter-proxy.py` (the `_or_capacity_*` block) types it; `agents/agent-session.sh`
    decides via three triggers (routed defer typed `or-capacity-down:*` in authoritative mode;
    `/router-status` → `.openrouter_capacity.down` in all modes; the credit floor).
  - evidence: `agents/rail-degrade-replay.sh` (CAP…CAP9, FAILOPEN…); replays
    `agents/replay/fixtures/rail-degrade`, `agents/replay/fixtures/go-rail-latch`;
    `router_openrouter_capacity_down`, `router_openrouter_account_credit_usd`.
- **The degrade's bounds are the rule**: `class=fix` only, semaphore-bounded (the degraded ride IS
  a claude ride, so FU-088 gates it unchanged), per-stack opt-out
  (`subscriptionFallback: false` / `AGENT_SUBSCRIPTION_FALLBACK=0`, read `== false` never
  `// false`), and the claim's `modelDeny` binds.
  - anchor: `agents/agent-session.sh` (the degrade branch).
  - evidence: `agents/replay/fixtures/rail-degrade` rows.
- **A degrade is visible on three surfaces**: the pod label
  `homelab.teststuff.net/rail`, the `AGENT_RAIL` pod env, and the launcher's `POST /report` field.
  - anchor: `agents/agent-session.sh`; `router.py:record_report` (`run_reports.rail`).
  - evidence: `router_run_reports_by_rail_total{rail="subscription-fallback"}`.
- **Key-read discipline: read the boolean, never `reason`.** The proxy publishes
  `openrouter_capacity.reason` unconditionally while `down` is the latched verdict — a
  reason-keyed read would degrade the fleet forever from the first 429; an unavailable balance is
  *no balance* (fail-open with one visible line), never a low one.
  - anchor: `agents/agent-session.sh` (the `GET /router-status` read).
  - evidence: replay `agents/replay/fixtures/rail-degrade` (CAP5 the stale-`reason` trap, CAP4 the
    lost payload).
- **The coordinator/reviewer/retro override rules (ADR-094, settled #810):** an explicit CLI
  `--model` is an override (route skipped); a scan-supplied default (`coordinatorModel`) is a
  constraint with a fail-OPEN fallback; a retro `--cell` model is an explicit override (cells are
  experiment ARMS — the router may never collapse the A/B axis); `AGENT_MODEL` is the universal
  override. ADR-094 holds throughout: routing verbs are labels, never model ids.
  - anchor: `agents/resolve-model.sh`; `agents/coordinator-session.sh`,
    `agents/reviewer-session.sh`, `agents/retro-session.sh`.
  - evidence: replays `agents/replay/fixtures/resolve-model`,
    `agents/replay/fixtures/reviewer-route-carrier`.
- **Every role routes.** `goal-decompose`, the dispatch units, the reviewer and the responder/retro
  launchers all call `/route`; a class that must stay on one rail says so in
  `classes.<cls>.chain_head`/`rails` (`audit`/`research` pin `rails: ["openrouter"]` with a fusion
  head; `review` carries `chain_head: ["claude/sonnet"]`; `coding` carries
  `chain_head: ["deepseek/deepseek-v4-flash", "deepseek/deepseek-v4.1-flash"]` — the platform
  claim's per-stack ordering surviving as class policy, before the claim goes chainless).
  - anchor: `model-classes.json` → `classes`; `router.py:route`.
  - evidence: decision rows per role; `/router-status` → `decisions_24h`.
- **A platform claim is chainless when it has no chain** and refuses a chainless dispatch without
  an authoritative verdict.
  - **`unenforced`** for [the platform stack](agentstack.md) — Goal #1640 acceptance 6 (the claim still carries
    `workerModel`/`workerModelFallbacks` at `routerMode: shadow`; the chain-walk paragraph in the
    brief and the runbook's `--model` step are deleted only by that acceptance).

### The OpenRouter API surface (probed — the one reference)

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
| MCP `https://mcp.openrouter.ai/mcp` | `list-daily-model-rankings` (rotation feed, top-30 daily, live since 2026-07-27), `list-models`/`get-model`, `search-docs`, **`list-benchmarks`**, **`list-task-classifications`**, `get-endpoint-uptime-history`, `list-presets`/`get-preset` | standard API key works for rankings (no OAuth dance, 2026-08-02); full tool set via OAuth (7-day key, $10 cap, includes BILLABLE `send-message`). Probed 2026-08-03 (OAuth): `list-benchmarks` sources = `artificial-analysis` (AA intelligence/coding/agentic composite indices, ~126 models) **and `openrouter` — OpenRouter's OWN evals (gpqa_diamond accuracy + $/task), i.e. the formerly session-gated frontend data**; `list-task-classifications` = 7d traffic share per task tag (incl. `code:devops_config`, `devops`, `security_audit`, `research_report`) with top-10 models each; `get-endpoint-uptime-history` = 72h hourly per-provider uptime **with quantization in the endpoint label** (fp8/fp4 — the provider-staleness filter's data). **Probed 2026-08-03: the standard account key pulls `list-benchmarks` AND `list-task-classifications`** (jail replay of the proxy's exact `_mcp_call` shape with the `router-account-key` Secret) — the scout's weekly capability/market pull is fully automatable server-side; OAuth is only needed for the interactive/billable tools |
| provisioning keys API | mint per-run capped keys (the ADR-081 runtime-key design) | scout canary keys ride this with `only-free` guardrail (FU-024) |
| frontend `/api/frontend/v1/stats/effective-pricing?permaslug=` | per-provider 30d market effective prices + REAL cache-hit (the market price basis) | works **unauthenticated** (2026-08-26). ⚠ takes the **DATED permaslug** (`deepseek-v4-flash-20260731`), never the model id (`…-0731`) — the wrong form returns an EMPTY payload, not an error. The proxy already derives it from `/endpoints` tag names (`_PERMASLUG_RE`); a hand probe must too. Ranks effective **input** price only — output price and quality are not in it |
| frontend `/api/frontend/v1/stats/tool-call-error-rate?permaslug=` | per-ENDPOINT daily tool-call error-rate series (the Performance-tab modal's data — the Auto Exacto quality signal itself) | found 2026-08-26 after the RSC row below couldn't reach it (the tab lazy-loads); unauthenticated; endpoint ids join to providers via `endpointStats`/`/endpoints`. The live-floor input for provider selection + a fleet alerting feed (a provider at 39.6% tool-error read 99.6% *uptime* — "up" ≠ "works") |
| model-page RSC stream (`GET openrouter.ai/<author>/<slug>` + `RSC: 1` header) | the Performance-tab data as React-Query dehydrated state, keyed by dated permaslug: **`benchmarkScores`** (per-provider Auto-Exacto benchmark rows — gpqa_diamond + TAU-Bench score, `run_count`, `endpoint_id`, 32d rolling — the quality table behind Exacto routing), **`endpointStats`** (per-provider latency/throughput **percentiles** p50–p99, `is_deranked`, `capacity_tpm`, quantization — richer than `/endpoints`), **`appStats`** (daily model-level `total_tool_calls` + `requests_with_tool_call_errors` → the model-wide tool-call error rate), `uptimeRecent`, `topColos` | probed 2026-08-26 (the 0731 read). Unauthenticated. ⚠ the PER-PROVIDER **Tool Call / Structured Output Error Rate** table lazy-loads on tab open and is NOT in the initial stream — its endpoint is unfound (candidate paths under `/api/frontend/v1/stats/*` all 404); the website is the only reader today. The signal is still CONSUMABLE blind: **Auto Exacto** reorders providers by it on every tool-calling request by default, and the **`:exacto`** model-variant suffix applies it explicitly — ⚠ an explicit `provider.order` pin presumably suppresses it (unverified; the 0731 matrix run tests this) |

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

## Who owns which fact

**Operator ruling, 2026-09-14** (with its 08:39Z refinement) — the routing state has exactly one
owner per fact; every other consumer ASKS:

| fact | owner | rule | anchor / evidence |
|---|---|---|---|
| live cell state — the `(model, provider)` cooldown + the per-cell hold | **the router** (`router.py`), served on `GET /router-status` and `/metrics` | the scan *asks* the router which cells are cooled; it never walks strike comments to reconstruct it (Goal #1640 acceptance 5's reader half — the fleet reader reads `/router-status` → `pair_cooldowns` each pass and fails closed when it cannot) | anchor: `router.py:pair_cooldowns`, `router.py:status_summary`, `agents/coordinator-scan.sh` (the fleet reader's `/router-status` ask); evidence: replay `fleet-reader-rekey`, `router_cell_cooldown{model,provider}`, `/router-status` → `pair_cooldowns` |
| the GitHub-side facts (labels, PR state, checks) | **github-exporter** — and only these | the monitoring surface for routing is the router's own gauge, not a GitHub-derived one | anchor: `argocd/` github-exporter resources; evidence: `router_cell_cooldown` scrape |
| key and budget lifecycle (mint, cap, credit, top-up) | **openrouter-operator** | nothing else mints or budgets a key; the proxy only *reads* the resulting balance | anchor: `agents/fixer/openrouter-operator/`; evidence: `router_account_credit_usd` |
| durable history (what happened, per run) | **the ledger / the router store** | history is never a live signal: a decision reads the cooldown/strike state, never "what the comments said" | anchor: `agents/ledger.py`; evidence: `/router-status` → `rows`, `generations_24h` |
| a dispatch-blocking alert | **the monitoring surface** | the fleet-level boolean is "a dispatch-blocking alert is firing" — **never a strike count**; a bad CELL is never a fleet event | anchor: `router.py:metrics_lines` (`router_cell_cooldown` is the per-cell surface; the router alert rules are `argocd/resources/openrouter-proxy/agent-router.promtool-rules`); the "fleet boolean = a dispatch-blocking alert" refinement is **`unenforced`** — operator direction 2026-09-14T08:39Z, no owner yet |

## Unenforced rules and their owners

Every rule above that this doc cannot anchor names its owner here, so the post-theme refresh is a
grep rather than a re-read (Goal #1640 acceptance numbers are the goal's own). **Audited against
master 2026-09-17 (homelab#1709 — the post-theme-1 flip pass): the theme-1 rules carry anchors in
the body above and have no row here** — the strike vocabulary (`router.py:STRIKE_CLASSES` /
`SERVING_CLASSES`), per-task enforcement + cell pricing (`router.py:route`), the per-session pin
(`openrouter-proxy.py:pin_for`) and the pair cooldown (`router.py:pair_cooldowns`) assembled with
homelab#1665/#1666 via PR#1734. The rows below are the residue:

| rule | owner |
|---|---|
| across-rails cost ladder decides the SERVED pick (shadow today) | FU-095 — its recorded next step IS the flip child ("the ladder promotion into the served path", [`../follow-ups.md`](../follow-ups.md)); no child minted yet |
| `pin-v2` for the priced classes (quality tie-break, benchmark floor, live tool-error floor) | Goal #1640 acceptance 8 (evidence base) |
| latency tie-break on measured decode tokens/sec | proposed, no owner — homelab#22's harvest half LANDED (`generations.generation_ms`, `router_observed_decode_tps`); the ordering lever (nothing reads the series) is what is unbuilt |
| `goose-32602-truncation` as a per-cell signal | proposed, no owner (operator direction 2026-09-14) |
| the finalizer/watchdog producer half of the strike vocabulary, and the storm-watchdog kill | Goal #1640 acceptance 1 (agent-runtime half) |
| launcher retry at worker-terminal | Goal #1640 acceptance 4 |
| strike READERS migrated off the comment to the router store | proposed, no owner (operator ruling 2026-08-19; blocked on the storage-engine question) |
| the platform stack chainless + `routerMode: authoritative` | Goal #1640 acceptance 6 |

## The problem, from evidence

Three incidents, three different lessons, one root cause — **the worker model was a single
hardcoded constant with no feedback loop** (the rules above are the answer; this is why they
exist):

1. **qwen $5.79 on a ~$0.30 task (2026-06-29).** No `provider` field → OpenRouter's default routing
   (a 1/price² *lottery*, not a floor) drew AtlasCloud at ~$1.15/M effective, **0% caching**, for all
   187 requests. Lesson: the *effective* price (provider + cache-read price × hit rate) is the only
   real price; headline price and "reliability" routing both mislead.
2. **owl-alpha 404 mid-run (2026-06-30).** The cloaked free model was rotated out. The reaction was
   the doctrine — "don't chase free/cloaked, pick ONE cheap reliable paid model" — hardcoded into
   the brief, the estimator table, and the launcher.
3. **oracle-fleet issue #1 (2026-07-09).** That ONE reliable model (deepseek-v4-flash) died 2 of 4
   rounds to a systematic ~15k tool-call truncation that recipe rules can't fix. r3's *triple infra
   failure* consumed the last round → `agent/blocked` → a human, ~12h later, for something no human
   decision was needed on. **The round budget was spent on infra, not the task.**

The doctrine from incident 2 is a **stale remembered status** (the failure mode the homelab
CLAUDE.md warns about for SERVICES.md): the "≈8 rpm free tier" figure is from 2026-06-30, free-tier
limits are account-balance-dependent, and — measured live 2026-07-09 — there are **19 `:free`
models advertising tool support**. Reliability is a *measurement*, not a constant.

## The sleep-stack pilots — task-class routing + multi-harness evidence (FU-095)

Direction 2026-07-25. The downstream consumer is the IdP project's **reasoning** agents (auditing,
requirements, monitoring — *not* coding), so the pilots have to produce evidence about a class of
work the coding lane's rules were never written for.

> **`unenforced`** — the whole section is a pilot programme, not rules: it is owned by FU-095 and
> gated on FU-080 (sleep graduation) + FU-044 (unattended deploys). The two rules it DID land are
> anchored where they live: the reasoning-tier classes in `model-classes.json`
> (`audit`/`research` → `rails: ["openrouter"]` + a fusion head; `dispatch`/`goal-decompose` as
> their own classes) and the rotation feed (`router.py:record_rotation`).

**Three operator corrections that shaped it:**

- **Sleep specs + evidence are a prerequisite, not optional.** Comparable model results across
  projects need the same evidence discipline; without specs the loop can't run reliably on sleep.
  Sequencing: specs discipline (oracle-style, adapted) lands **with or before** graduation.
  · **`unenforced`** — FU-095.
- **The candidate source is a maintained ROTATION**, not the scout's new-model diff. The scout
  missed `nemotron-3-ultra-550b:free` — verified: the registry snapshot predates it *and* kimi-k3.
  Diff-only + tools/price filter ≠ "what's currently good". The rotation feeds chains
  continuously; the scout's canary leg stays as the safety probe for rotation entrants.
  · **`unenforced`** — FU-095.
- **Reasoning tier for audit/review/research task types.** The coordinator README currently *bars*
  reasoning models — a worker-coding rule. The audit/research lane needs its own, including
  **dual-model review** (two models on one audit is worth the tokens here, unlike coding). Budget
  shape for IdP pre-build research: a few review rounds on a large model (e.g. kimi-k3), never N
  full designs from scratch.
  · **`unenforced`** — FU-095 (the landed parts are the reasoning-tier classes in
  `model-classes.json`).

**Leg (a) — task-class-aware model choice at dispatch.**
- **`unenforced`** — FU-095 leg (a); the class lookup itself landed as the `label_map` +
  `capability_floor` rules above. Its first axis is **repo-type**: an `-iac` devops chain is not an
  app coding chain ([`iac-lane.md`](iac-lane.md) §Model class).

> **Buy-vs-build, surveyed 2026-07-27 → BUILD the small lookup.** External routers solve
> per-*prompt* difficulty inference (RouteLLM / NotDiamond / openrouter-auto — popularity- or
> classifier-based, and none can read our ledger) or gateway mechanics (LiteLLM / Portkey — which
> would un-solve the proxy's subscription gate and cred/pin injection). Closest fit is
> **OpenRouter presets** (`@preset/<class>`, server-side chains) — dashboard-managed today, i.e.
> click-ops; watch for API manageability.
> Two registry enhancements adopted from the survey: **(1)** a provider quantization/staleness
> filter in the provider pin (the `/endpoints` field — never pin an fp8/stale serving for
> eval-sensitive lanes); **(2)** "sales" need nothing — live effective-price recompute per dispatch
> already captures price drops, and the rotation covers currently-good drift.
> **(3) `openrouter/fusion`** (operator find, same day): a panel-deliberation router — the
> audit/research **class chain head** candidate, mechanizing the dual-model directive in one
> ~4–5× call, with server-side web reach solving part of the FU-105 egress dial on the OpenRouter
> rail. Panel pinned via `analysis_models` launcher-side; **never** a fixer-lane entry (landed as
> `classes.audit/research.chain_head`).

**Leg (b) — multi-harness evidence.**
- **`unenforced`** — FU-095 leg (b).
  The same task classes across `--harness goose|opencode|claude`, compared on the FU-057 ledger
  axes {success-rate, harness-death-rate, $/successful-issue}. This *is* the recorded ADR-077
  trigger ("add Omnigent's meta-harness only if governing multiple harnesses becomes real") — the
  pilot supplies the evidence that decision is waiting on.

**Leg (c) — free-model probing of goose error handling.**
- **`unenforced`** — FU-095 leg (c); the scout's canary shape is anchored in the class rules above.
  Extend the canary from trivial closed rides to real sleep xs tasks. This resolves the live
  tension between "free entries are fine anywhere" and `stacks.json` `_chain_policy` ("free tiers
  never fix-chain entries").

Renovate-majors piloting on sleep is **not** this — that's FU-046's existing lane.

**Terminology ruled (2026-07-27):** **"system testing"** = logic against real components in kind
(Garage + ingester + Grafana + Playwright, the ADR-082 shape); **"e2e"** is reserved for the actual
target environment (synthetic production traffic). Cf. Fowler's microservice testing pyramid —
our "system" ≈ his out-of-process component / limited e2e.

## The bundle — why these FUs resolved together

_All five archived (2026-07-12…07-25); the table stays as the design rationale, not as rules._

| FU | role in this design | without it |
|---|---|---|
| **FU-062** (this doc) | strikes vs rounds, chains, registry, scout | the single-model lock stands |
| **FU-057** | `error_class` + served model/provider/cache-hit in the ledger | strikes unclassifiable, blacklists blind |
| **FU-018** | provider pinning injection (opencode now, proxy for goose) | effective price unenforceable → $5.79 repeats (cap-bounded) |
| **FU-021** | goose hard-stop on auth/limit errors | a strike burns its whole session cap in a retry storm first |
| **FU-024** | enforced only-free guardrail | scout/free keys are honor-system |
