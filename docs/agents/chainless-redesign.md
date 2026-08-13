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
6. **Build mode: jail subagents author, the platform loop only reviews.** The redesign is built
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
- **The compat boundary (bisected exhaustively, both directions):** `/v1/messages` REJECTS
  Anthropic-shaped tools (422 — the validator union appears server-tool-only; every one of
  claude-code's 52 function tools and a minimal hand-made one) and silently DROPS OpenAI-shaped
  tools before the model — while the same models tool-call perfectly on `/chat/completions`
  (`finish: tool_calls`). Plain completions work end-to-end. Two more quirks, both normalized in
  the jail shim: string-shorthand message content is dropped by glm (free-associates; blocks form
  fine), and claude-code's `?beta=true` + `anthropic-beta` decorations 422.
- **Consequence: an Anthropic⟷OpenAI translator is on the critical path** (requests: messages/
  tools/tool_result → OpenAI; responses: `tool_calls` → `tool_use` blocks; SSE event
  re-synthesis), targeting `/chat/completions`. It is the same component the egress proxy needs
  for the Go rail, so the jail shim builds it first and the proxy inherits it.

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

1. Shim translator leg (Anthropic⟷OpenAI vs `/chat/completions`) → tool-capable Go subagents.
2. Rail canary cells over Go models (claude harness) — pick the working set.
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
