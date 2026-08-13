# The chainless redesign — one harness, N subscription rails, every role routed (ADR-107 charter)

**Status: CHARTER (operator direction, 2026-08-13 — the subscription-autopsy session). Design
accepted in principle; build NOT started.** This doc owns the redesign's decisions, the claim-knob
ledger, the OpenCode Go rail evidence, and the build plan — so the direction survives any one
session. Routing mechanism stays owned by [`model-routing.md`](model-routing.md) (§M8–M13) and the
claim by [`agentstack.md`](agentstack.md); this doc records what CHANGES in each and why. The
decision record is **ADR-107**; the day's probe evidence is TICK-LOG 2026-08-13.

Trigger: the Anthropic 7d window at 87–89% while the router could steer nothing that mattered —
67% of the pool is the jail seat, ~28% platform roles that never call `/route` (§M10), and the one
routed lane ran shadow. Plus the same day's proof of how expensive fused model semantics are: every
`claude/haiku` worker ride had run the CLI default (opus-5[1m]) for 23 days because the model rode
an env var only goose read (PR#407).

## The decisions (operator, 2026-08-13)

1. **Chainless everywhere.** `routerMode: authoritative` becomes the only mode; static chains
   (`workerModel`/`workerModelFallbacks`) are deleted, not deprecated-in-place — "do all the
   model-routing work that chainless needs, drop all legacy at once."
2. **Every role routes.** Coordinator, reviewer, responder, retro, prober wire to `/route`
   (closing §M10's unrouted-lane gap — the lanes holding ~28% of the subscription pool). Doctrine
   (safety net, decorrelation, audit bands) moves to git-owned class policy
   (`model-classes.json` floors/rails + the claim's constraints), never hardcoded models.
3. **One harness.** The claude CLI serves every rail; goose/opencode demote to FU-095(b)
   experiment cells. Rail + model are a routed decision materialized as base-URL/credential/model
   translation at the egress proxy — the pod is spawned identically regardless. Dispatch never
   pre-computes a harness. (Accepted trade, stated: the client becomes a monoculture — a
   claude-CLI bug is fleet-correlated; the RAILS stay independent, which is what the M12
   independence ruling actually protects. Version-pinned image + strikes carry it.)
4. **OpenCode Go is the second subscription rail** ($10/mo; usage-value windows $12/5h · $30/wk ·
   $60/mo; 18 OSS models incl. the retro-proven audit tier; Anthropic- and OpenAI-compatible
   endpoints). The M11 ladder generalizes: the zero-marginal-cost band holds a SET of
   subscription rails, each with its own FU-088-pattern capacity gate, and the router picks the
   **most available subscription first** (per-rail binding-window headroom; reset epochs trusted
   over utilization numbers — the 57-min-stale-header lesson), then paid API as the spender of
   last resort. Codex/Copilot are candidate third rails — self-metered (no headroom headers;
   the proxy's own per-window token ledger, corrected by observed 429s) and ToS-checked before
   adoption (Go explicitly sells API access; Copilot's headless-agent terms are murkier).
5. **Queueing behind the latch is edge-woken.** A capacity-deferred dispatch stays a GitHub-label
   fact (the queue IS the level-triggered re-list — never an in-proxy work queue); what's new is
   the **capacity doorbell**: the proxy knows every window's reset epoch and rings `/coordinate`
   on a latch's limited→ok transition, so 🧊 CAPACITY waits convert to edge-woken resumes
   ("ALL EVENTS HAVE DOORBELLS" applied to windows).
6. **Build mode: jail subagents author, the platform loop only reviews.** Bootstrap-phase
   refinement (operator, 2026-08-13): chunks are **double-reviewed** — the seat reads the
   worktree diff pre-push, then the review reflex reads the PR — and every miss lands in the
   [decomposition-rules ledger](../spikes/subagent-handover-misses.md), which is what earns the
   seat gate's later narrowing. The rollout ladder for every piece of this program is the
   standing method: **jail-first → platform piece → platform-stack dogfood → stack rollout**
   (the Goal loop bootstrapped the same way; opencode-go cannot be a platform reviewer before
   it has been jail tooling). The redesign is built
   from jail sessions fanning mechanical chunks to Go-slot subagents (`homelab-go`); the cluster
   loop's role is bot PR review. Slot mapping is launch-time env; per-call slot selection
   (Agent tool `model:`) is the size-tiering mechanism.

## The claim-knob ledger (AgentStack, target shape)

The principle: **the claim stops naming models and starts naming constraints** — everything
selection-shaped moves behind `/route`.

| | knobs |
|---|---|
| **Removed** | `workerModel`, `workerModelFallbacks`, `coordinatorModel`, `reviewer.goalModel`, `subscriptionFallback` (the ladder subsumes M12's special case), `fixer.claudeTier` (below), `fixer.guardrail` (incoherent without a fixed chain — per-session caps + rail budgets bound spend), `prober.model`. `routerMode` survives only as the per-stack migration flip and is deleted last. |
| **Kept** | `modelDeny` (entries migrate to FU-127's structured `{rail, model}`), `fixer.budgetUSD`/`resetInterval` (the OpenRouter-rail standing ceiling), and everything that was never model semantics: `docker`, `egress`, `storage`, `labels`, `argo`, `mainRepo`, `coordinator.enabled`, `reviewer.enabled`, `loop.*`, `repos[].fixer`-presence as the dispatchability predicate (IAC-T03). |
| **Added** | `rails:` — allowed-rails list per stack (or per class): the M12 independence ruling as declared policy (platform fix-class = `[anthropic-subscription]`), and a stack's Go opt-out. `classPolicy:` — per-stack class→band/floor overrides, the ONE seam replacing every per-role model knob. Per-rail **budgets** (`openrouter:` USD · `opencodeGo:` usage-value · `subscription:` window-share) — the #278 rail-aware charter's claim surface. |

**`claudeTier` is deprecated** because both its jobs dissolve: harness-from-string dies with the
uniform harness, and the per-ns `claude-session` secret render becomes platform-unconditional —
or better, rail credentials resolve at the proxy by namespace identity (the git-token broker
pattern), leaving **no per-ns LLM secret at all**. The two-part model string (`claude/haiku`,
`openrouter/vendor/model`) survives only as legacy input to `model_id.py`; the routed RESPONSE
(`{rail, model, …}`) is the semantic carrier (FU-127's structured form — a third string segment
like `claude/anthropic/haiku` was considered and rejected: it would be a second grammar to
migrate through).

## The OpenCode Go rail — probed facts (2026-08-13, wallet key `opencode-go-api-key`)

- Endpoints: `https://opencode.ai/zen/go/v1/messages` (Anthropic-compat) ·
  `…/v1/chat/completions` (OpenAI-compat) · `…/v1/models` (25 live ids). **Bearer auth works**;
  `/v1/messages` additionally demands `x-api-key` (send both). Cloudflare 1010-blocks the
  python-urllib UA (probe artifact — curl and header-less http.client pass).
- Pricing publishes **cached-read rates** — the decisive column: the platform's token shape is
  cacheRead-dominated, and at GPT-5.6-Luna-class rates a full reviewer-lane week ≈ $12 of usage
  value (fits $30/wk); at Grok-class rates it does not. Model choice inside Go decides capacity.
- **The compat boundary — REVISED same day: it is PER-MODEL, not endpoint-global.** The first
  bisect (glm-5.2) read as endpoint-wide: Anthropic-shaped tools 422, OpenAI-shaped silently
  dropped, models tool-calling fine on `/chat/completions`. The homelab-go session's per-model
  probing then split it: **qwen3.5-plus, qwen3.8-max and kimi-k3 accept Anthropic-shaped tools
  and return proper `tool_use` blocks** (`stop_reason: tool_use` — re-verified independently at
  takeover), while glm-5.2 422s every function tool and deepseek-* is region-locked (403). Two
  quirks stay normalized in the jail shim: string-shorthand message content (glm drops it;
  blocks form fine) and claude-code's `?beta=true` + `anthropic-beta` decorations (422).
- **Metadata surface (probed 2026-08-13): registry-POOR.** `/v1/models` returns ids only — no
  pricing, no multipliers, no quota API ("track your usage in the console"; docs admit "for some
  models, their usage multiplier is lower" with NO numbers — the actual multipliers appear only
  in the opencode client's picker: DeepSeek V4 Flash and GPT-5.6 Luna show "(2x usage)").
  ⚠ **The "Nx usage" SEMANTICS are UNRESOLVED** (operator challenge, 2026-08-13): the docs'
  *"$10 → 6x that in usage… for some models the multiplier is lower"* reads as a per-model
  VALUE-POOL ratio (badge = downgraded pool, $20/mo instead of $60 — also decodes the table's
  $15/$60 "Usage" column as 1.5×/6× pools, with picker↔docs drift = live ops tuning), but
  "you get 2× usage" (a discount perk) is equally consistent with the badge text alone. The
  tell leaning pool-reading: the badges sit on CHEAP models (Luna, flash), not the expensive
  ones. DECIDED BY: the console's per-model usage-$ against list-price token math on a known
  request (operator console glance — no API). Do not build window accounting on either reading
  until that datum lands.
  Contrast OpenRouter's models/endpoints/generation APIs + MCP: the Go-rail registry must be a
  **curated snapshot** (the §M8 gated-data pattern) — docs pricing table + picker multipliers +
  our own per-model canary matrix — with windows self-metered from per-request usage.
- **The Zen sibling**: the same key reaches `…/zen/v1` — opencode's pay-per-token GATEWAY (60
  models incl. `claude-*`; never route claude there — the Anthropic subscription exists) with a
  **free tier**: `deepseek-v4-flash-free`, `mimo-v2.5-free`, `hy3-free`, `nemotron-3-ultra-free`,
  `nemotron-3.5-lightning-free`, `laguna-s-2.1-free`, `big-pickle` — a candidate rung-0 on this
  rail (mostly the same models as the OpenRouter free rung). Tool-compat UNPROVEN (first probes
  400) — canary before any slot use.
- **Slot economics (curated 2026-08-13; unit = 1M cacheRead + 100k output, the subagent shape):**
  mimo-v2.5 ≈ $0.031 (cheapest priced, unbadged — but tools 400 on the compat path today) ·
  deepseek-v4-flash ≈ $0.031 at list AND **region-locked 403 for us — out regardless of math** ·
  qwen3.7-plus ≈ $0.20 · qwen3.8-max ≈ $0.85 · glm-5.2 ≈ $0.70 (tool-broken) · kimi-k3 ≈ $1.80
  (sparse big calls only) — against $12/5h·$30/wk·$60/mo usage-value windows. The haiku slot
  KEEPS `qwen3.5-plus` — it is the one proven tool-caller in the cheap class, though **unpriced
  and undocumented** (absent from the docs table AND the picker; flag: pricing may surprise).
  Next probe: kimi-k2.7-code ($0.19/M cached, $60 usage, 1×) as the priced cheap-slot candidate.
- **Consequence: the Anthropic⟷OpenAI translator is OPTIONAL, not critical-path** — it only
  widens the model set beyond the tool-verified trio. What replaces it on the critical path is a
  maintained **per-model tool-compat matrix** (the rail-canary shape): a Go model enters a slot
  only after its `tool_use` round-trip passes. First Go-served subagent ran 2026-08-13
  (~14:45Z, qwen3.5-plus; OTLP-confirmed `query_source=subagent` with zero Anthropic draw).

## Jail tooling (the working prototype — shipped PR#409/#410 + claude-jail)

`scripts/claude-model-shim.py` (local rail split: route by body model id, credential per rail,
oauth never crosses to Go — self-tested + live-proven) · `scripts/claude-go.sh` (claude-or
pattern; slot map from gitignored `.opencode-go.env`: haiku→glm-5.2, sonnet→kimi-k3,
opus→deepseek-v4-pro, subagent default glm; main model — fable — stays subscription;
`CLAUDE_GO_ALL=1` for pure-Go) · claude-jail alias `homelab-go` (upload port 8012). The shim is
deliberately the M11 rail-split shape so lessons transfer to the proxy.

## Preconditions before the fleet flip (acceptance criteria)

1. **Requested≠served belt** — a deterministic drift check joining the launcher's requested model
   to the served model (OTLP/generation records). PR#407's class was visible for 6 days in data
   already collected; alias remapping per ride makes silent drift MORE likely. No existing FU
   covers it (grep negative, 2026-08-13).
2. **Rail-aware accounting** — `AGENT_RAIL` folded into stats/`run_reports` (M12's
   declared-unconsumed surfaces), then #278's summation across three currencies (window-draw /
   usage-value / USD). FU-131's sweep relates.
3. **A rail-probe canary per (model, class) cell on the Go rail** (§M7 leg 3 machinery) before
   fleet exposure — compat fidelity is per-model, as the glm shorthand bug showed.
4. **P4-flip evidence** — the shadow ladder read with real urgency data (the caller gap closed
   2026-08-13, PR#408: labels + work-branch urgency now ride `/route` bodies).

## Build order (jail-subagent chunks; platform loop reviews)

1. ~~Shim translator leg~~ **DONE DIFFERENTLY 2026-08-13**: per-model probing found a
   tool-verified trio (qwen3.5-plus / kimi-k3 / qwen3.8-max) — Go subagents are live on the
   slots without any translator; it returns to the backlog only if the working set proves
   too narrow.
2. Rail canary cells over the remaining Go models (claude harness) — grow the compat matrix.
3. Proxy: Go rail (ref cred, self-metered windows, latch, ladder rung) + capacity doorbell.
4. `/route` response as the structured carrier; claim/XRD reshape per the ledger above;
   `model-classes.json` grows rails/class policy.
5. Role wiring (coordinator/reviewer/responder/retro launchers call `/route`).
6. Legacy deletion in one sweep: chains, `claudeTier`, `guardrail`, the M12 branch, the M10
   case-maps, `REVIEW_GOAL_MODEL`, `GOOSE_MODEL` threading — each deletion site is already
   named in its own doc.

## Related

ADR-107 (decision record) · [`model-routing.md`](model-routing.md) §M8–M13 (mechanism home; M11
generalizes, M12 folds in) · [`agentstack.md`](agentstack.md) (claim) · FU-095 (routing program
pointer) · FU-127 (structured `{rail, harness, model}`) · FU-131/#278 (accounting) · FU-168
(dispatch throughput) · the banked tier-thesis revision (TICK-LOG 2026-08-13 — review leverage =
decorrelation + tool-grounding, not tier; feeds class policy when piloted).
