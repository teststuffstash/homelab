# 2026-08-26 — the authoritative review plane was dead (reviewer 404-loop, FU-188)

**Impact:** zero review verdicts on every `routerMode: authoritative` stack — oracle from its
13:58Z chainless flip (~6h to discovery), sleep from 18:05Z (latent — no reviewable PR crossed
it), circles latently since 2026-08-23 (no positive evidence any reviewable PR crossed the dead
path; its last verdict predates it). ~72 role=reviewer route calls/24h produced **zero
generations**. The platform stack was untouched (`routerMode: shadow`), so the review plane the
operator watches daily — homelab's own — stayed green throughout. Discovered only because the
seat was hand-watching oracle-fleet#277's review (two dead rounds, 19:47Z + 20:00Z); pinned at
20:05Z (`1596e395`), verified live at 20:22:54Z (sonnet verdict on #277).

## Root cause

PR#803 (2026-08-23, the G-A role-wiring child) made the reviewer consume `/route` verdicts and
deleted its static sonnet failover in authoritative mode, on a stated assumption: *"the class
policy orders the subscription rail first, so behaviour is unchanged while capacity is ok."*
The config half was true (`model-classes.json` class `review`: `rails: ["subscription",
"openrouter"]`). The served walk made it vacuous:

1. the reviewer sends **no chain** (by design — "the class policy orders the rails
   server-side") → candidates come from `_rotation_candidates()`;
2. the rotation universe is `model_tiers ∩ daily-rankings` — **OpenRouter ids only**; no
   `claude/*` can appear;
3. rail is derived per candidate (`startswith("claude/")`), so the subscription pool was
   **always empty** — and an empty pool is skipped **silently** (no skip-reason row);
4. the synthetic subscription candidate exists only in the **shadow ladder** (M11a —
   homelab#159 shipped shadow-only; the served walk has no counterpart);
5. the openrouter rail therefore won every pick — and its capacity gate passed with
   `key_ref: null`: the gate asks "can the *account* buy", never "can the *caller* ride".

The adopted market id hit a pod hardwired to the `/anthropic` surface
(`ref:coordinator-claude`) → instant Anthropic 404 → no verdict → and no `/report` ⇒ no
strike ⇒ the router re-picks forever.

**Why only the reviewer died:** `dispatch`/`goal-decompose` declare `rails:
["subscription"]` — their routes deferred typed on the same empty pool and the launchers'
fail-open `--fallback sonnet` literals served them. `review`'s second rail entry —
one YAML token — converted "defer + fallback" into "serve a dead pick".

## Why nothing alerted (the belt audit)

Every belt missed for a different structural reason:

- **Strikes/cooldowns** — `/report` is the worker launcher's finalize path; the reviewer has
  no report call, so api_error terminals taught the router nothing (FU-188 leg c).
- **Both requested≠served belts, out of scope by their own keys** — `agent_model_unverifiable`
  (exporter side) keys on requested *claude* models: this request adopted a non-claude id.
  `RouterRunModelUnverifiable` (router side) is fed by `/report` rows the reviewer never
  writes. Each belt's description names the other as covering the remainder; the reviewer fell
  in the seam between them. (The `AgentModelUnverifiable` firing that evening was
  `oracle-fleet/worker` — the FU-187 quiet-stall class, a different incident — so the family
  was also already crying wolf.)
- **The exit contract (homelab#560) worked and terminated in a void** — dead sessions
  correctly redded their Argo workflows; **zero PrometheusRules read `argo_workflows_*`**, so
  red review workflows have no alert consumer.
- **The review lane's breakers are all over-activity detectors** — AgentReviewLoop (>3
  verdicts/h), the FU-069 impossible-count layers. Zero verdicts trip nothing; there is no
  "reviewable PR without a verdict for Xh" belt anywhere (Part A′ named the panel in July; it
  was never built as an alert). Activity metrics read *busier than normal* — the
  counter-vs-throughput trap at fleet scale.
- **The shadow evidence existed and had no discriminating reader** — every reviewer run since
  08-23 logged `dispatch <market-model> (static would be: sonnet)`, and
  `router_shadow_decisions_total` held ~524 `agrees=0` subscription-rail rows over 7d — but
  the fleet's shadow-divergence baseline was already ~90%, and the P4 "read shadow_24h before
  promoting" discipline was attached to the P4 flip, which never happened: the **chainless
  stack flips promoted the reviewer de facto on worker-only evidence** (the flip knob is
  per-stack; the change was per-role).

## The generalized cause — three instances in one day

The same day produced a sibling: opencode's un-suppressible, timeout-less SDK-init fetches
wedge rides pre-LLM under `enforce: true` egress (homelab#990; two 4h slots burned on
oracle#272). Both fixes were the same shape: a **hand-written launcher literal** saying "never
serve X in situation Y" (PR#991: enforced-egress rides never default to opencode; the FU-188
pin: reviewer never authoritative), each replay-pinned, each awaiting a durable home. The
combination knowledge — which role × harness × rail × model combinations work **today** — is
smeared across six homes (class rails in `model-classes.json`, canary verdicts in the rotation
store, the Go matrix spike doc, launcher literals, the reviewer pin, prose in
platform-and-stacks §Composition axes) with no machine join. The router serves combinations
that a constraint elsewhere already knows are broken.

**Operator ruling (2026-08-26 evening, this incident's design outcome):** the standing
yaml-in-git pattern applies — a declared combination table in git, rows as **dated
current-state claims with a status axis** (`works | not-yet | disabled(reason → link)`),
never permanent laws: "reviewer never rides openrouter" is a `not-yet` (shadow re-reviews on
`opencode-zen/big-pickle` — #923's arm — and `:free` reviews are valid future rows), and
disabling a combination becomes a one-line status flip instead of a bash edit. Joined with
the evidence data (canary verdicts, outcomes) per the github-exporter pattern; a viewer piece
later. Build home: FU-188 (the reshaped legs).

## Residual work

FU-188 carries it: (a) reviewer adopts only rideable rails; (b) the router never serves a
rail the request cannot ride — keyed on the declared table + the request's capability vector,
not role-name case maps — plus an explicit skip row for an empty preferred rail; (c)
api_error terminals `/report` ⇒ strike (also feeds the reviewer into
`RouterRunModelUnverifiable`, closing the belt seam); (d) zero-output detection — an
`argo_workflows_*` failure consumer or a verdict-throughput belt (the AgentQueueStalled
"liveness ≠ output-watching" lesson, review-lane instance). Process half: a stack flip's
checklist gains "enumerate the roles this arms; each role's authoritative path has ≥1
exercised run" (chainless charter flip-acceptance).

## Probe lesson

A role's route consultation in shadow is a per-run prophecy of exactly what authoritative
will do — but a divergence metric with a ~90% baseline cannot surface a new 100%-divergent
lane. Shadow soaks must be read **per (role, lane)** against the flip that arms them, not as
a fleet divergence rate.
