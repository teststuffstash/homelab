# The chainless redesign — a harness matrix, N subscription rails, every role routed (ADR-107 charter)

**Status: CHARTER (operator direction, 2026-08-13), build LARGELY EXECUTED** — chunks A–H
shipped (2026-08-13/14), role wiring landed via Goal G-A homelab#775 (2026-08-23: every role
routes), oracle + sleep run chainless (oracle-iac#387, sleep-iac#77), and the platform's
chainless flip rode the same wave; what remains is flip acceptance 2–4, the FU-186/ADR-115
provider legs, and build-order item 6 (the legacy-deletion sweep). This doc owns the redesign's
decisions, the claim-knob ledger, the OpenCode Go rail evidence, and the build plan — so the
direction survives any one session. Routing mechanism stays owned by [`model-routing.md`](model-routing.md) (§M8–M13) and the
claim by [`agentstack.md`](agentstack.md); this doc records what CHANGES in each and why. The
decision record is **ADR-107** (decision 3 superseded by **ADR-112**, the harness matrix); the
day's probe evidence is TICK-LOG 2026-08-13.

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
3. **Harness support is a MATRIX, not a monoculture — ADR-112 (2026-08-23), superseding
   ADR-107 decision (3)'s 2026-08-17 "one harness, temporary" text.** The old wording fused two
   senses: *sense A — full-support harness* (runs every role/reflex, serves every rail: both
   subscriptions, OpenRouter, free tiers) and *sense B — the dispatch-time pick* for a given
   ride. The ruling: **claude AND opencode both reach sense-A full support** — claude first
   (the beefiest subscription; its in-cluster OpenRouter leg is the missing rail), opencode
   promoted from experiment-cell to first-party (recipe support, headless permission config,
   full-id `-m`). Rail + model (+ harness) stay routed decisions materialized at the egress
   proxy; dispatch never pre-computes. **The scout probes every candidate across all three
   harnesses** — a verdict is the (model × harness) cell VECTOR, never one harness's failure
   (the ox-alpha 2026-08-23 evidence: three harness paths, three different outcomes, one
   model) — and failed cells retry on a backoff ladder (~1h/2h) before sticking. Goose remains
   a probed cell axis, not a build target.
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

### The corpus batch session (the jail lane's checkpoint model — added 2026-08-13)

The ADR-106 checkpoint shape applied to the jail: **pay the design-agents corpus once, at an
authoring moment, and amortize it over a BATCH** of jail-lane issues — triage (close/merge/
re-scope), decompose, dispatch. ⚠ The batch input filter was CORRECTED by ADR-109 (2026-08-17):
¬`agent-fix` is NOT the jail-lane marker — `agent-fix` means suitability, so a flagged-but-
unqueued issue is ALSO the operator's until queued. The batch input is the who-acts set
`devbox run board` renders (🌱 register + unlabeled strays + the suitable-unqueued backlog +
parks/latches). Triage sorts each survivor: seat work (needs
the corpus) · subagent chunk (mechanical, loud verification) · re-author into the agent lane
(cheapest — label it and let the cluster fixer ride) · operator decision.

**Isolation primitive: LOCAL CLONE, not worktree** (operator ruling 2026-08-13, homelab#428,
after four same-day instances of the repo-global-branch-refs escape class — two seat drifts,
two subagent stowaway commits, one caught end-to-end by the reviewer's withheld verdict +
`agent/error` + responder triage): `git clone --local /workspace/homelab <dir>` gives each
subagent its own `.git`/ref namespace, making boundary escapes structurally impossible instead
of documented-against; hardlinked objects keep it worktree-cheap, the warm-devbox line is
unchanged, and the seat integrates via `git fetch <clone-path> <branch>`. The operator's
standing lens: worktrees/submodules only where complexity requires them.

**The MAINTENANCE session (ADR-110, 2026-08-18) — the batch model gains merge authority.** For
the goalless stream (alerts, board items, fix-flow), the corpus-loaded session IS the codeowner
gate: the seat reads every master-bound edit against the corpus and merges when nothing
operator-significant surfaces — escalating the BIG (design forks, governance/gate changes,
budget semantics, new credentials, anything ADR-shaped) and landing the SMALL (alert-born
fixes, thresholds, doc currency, scaffold manifests) where wonky-for-days is accepted and the
alert belts are the net. The invariant: cluster identities still approve/merge NOTHING — the
seat's authority is the operator having started the session. The Goal lane keeps its own
checkpoints (corpus at decompose/assembly); this is the sibling for streams with no single goal.

**Session types & the watch contract (operator, 2026-08-19 — the watches-for-codeowner-sessions
sitting).** Three flows, now named: `/meta-coordinate` survives only to resume the coordination
ROLE (meta-state's session-type rule); the jail's day-to-day runs as two session types — the
**maintenance session** (the mechanical stream: pve, alerts, cilium/longhorn; agents issues only
when mechanical) and the **corpus session** (design-agents corpus loaded: codeowner reads, FU
build, subagent waves). Both arm the SAME standing watch set at bootstrap
([`meta-state.md`](meta-state.md) §Re-arm owns the arming practice and the cadence numbers); the
type sets only the act rule and the heartbeat cadence. The contract, distilled from the
2026-08-18 stall (PR#568's changes-requested sat overnight behind an ad-hoc watch while the
standing SEATPR source — built 2026-08-12 from exactly this class — sat unarmed):

- **A monitor costs nothing while silent; a DELIVERED event costs a tick of the session's whole
  context.** So events are placed by who must act: the main thread receives only seat-actionable,
  edge-collapsed events (the standing set + subagent terminals); everything else stays
  subagent-local or nowhere.
- **The standing set is the level-triggered layer; ad-hoc per-PR watches are edge triggers on
  top** and must cover EVERY terminal (new changes-requested, CI-red, breaker labels) — never
  merge alone. A stall only the operator catches is an arming defect, not bad luck.
- **On the corpus session, cache economics and the stall belt are ONE mechanism**: a wake within
  the ~1h prompt-cache TTL is a ~0.1× cache read, past it a full context re-read
  ([observability-and-retro.md](observability-and-retro.md) §Part A″ — a wait bills the context
  holding it). So the corpus heartbeat runs UNDER the TTL and doubles as the keep-warm; an
  expected past-TTL wait with nothing in flight is a deliberate wind-down, never an idle.
- **Mechanical reactions are delegated down, never executed up**: the seat's tick carries the
  judgment ("which reaction"), a subagent executes it. And no triage-brain sits between the watch
  scripts and the seat — deterministic filter → judgment seat, the scan→coordinator shape; a
  recurring mechanical reaction graduates into the script/reflex itself (the ≥2-pattern rule).
- **Issues either session type files bind at filing** (S6 / lineage contract rule 3): parent =
  the epic or origin issue the work serves, or `standalone` stated in the body — lineage is
  never implicit; the scan's unbound-sprout belt is the backstop.

**The jail stint (operator direction, 2026-08-19 — the Goal SHAPE without the Goal machinery; renamed from "wave" same day, operator catch: three existing senses).**
A bounded container for multi-session jail work: a parent issue titled `stint: <slug>`, label-inert
(never `task/goal`, never `agent/*` — the scan and the goal lane must not see it), with the work
as **native sub-issues**. Three rules carry the whole design:

- **Everything binds to the parent — per the EPIC lineage contract**
  ([issue-authoring.md](issue-authoring.md) §The lineage contract, the ONE home of the rules the
  stint shares with the Goal: bind-at-filing regardless of door, defects-never-release,
  originals/sprouts, single-parent absorption, close-at-tree-empty). Stint-specific on top:
  sprouts carry a provenance line naming the PR/issue they fell out of, and the parent IS the
  bound on the sprout tail the Goal lane needed a budget for.
- **Sizing is session-multiples, not budgets.** A `Size: N sessions` body line (1 / 2 / 3 — the
  natural pricepoints; a corpus-session arc is the unit, per §Session types above). No `Budget:`,
  no launcher gate, no reader — an authoring-time thinking aid, compared against actuals at
  closeout. (Context-tier sizing was considered and simplified away 2026-08-19: the session IS
  the natural quantum.)
- **Closeouts are MULTIPLE, and the first one is a full sweep, not a wind-down note.** Closeout 1
  fires when all ORIGINAL sub-issues (the set at stint start — snapshotted by the meta-events STINT
  source, which emits the burn-down and the `CLOSEOUT-DUE` edge) are done: a corpus sitting runs
  docs-cleanup over the touched surfaces, the FU sweep (file genuine leftovers, archive resolved),
  a built-vs-left-behind analysis as ONE parent comment (shipped / dropped / still open), and
  disposes every open sprout (do-now · keep as stint children · release to ordinary backlog with
  links · drop with a reason). The release and close semantics are the lineage contract's
  ([issue-authoring.md](issue-authoring.md) §The lineage contract, rules 4 and 6 — defects in
  the stint's deliverables never release; the parent closes only when the tree is empty), not
  restated here. Later closeouts repeat per sprout batch. Mixed execution is fine: a stint
  child that is fixer-shaped may be labeled `agent-fix`+`agent/queued` and ride the cluster loop;
  only the parent stays inert.
- **Tree-empty ARMS the close; it never executes it (operator rule, 2026-08-20).** The parent
  stays OPEN through a ≥72h quiet window (no new tree event) and closes at a LATER session's
  sweep. Rationale: bind-at-filing is enforced by salience — filers bind to what the board
  shows, and nearly all of the #420 tail repaired in the 2026-08-20 lineage sweep
  (#660/#674/#646) was filed while the container sat closed. GitHub accepts sub-issues on
  closed parents, so the mechanics never blocked — the visibility did. The Goal kind needs no
  counterpart: its terminals are human verdicts and post-launch already holds it open (the
  ADR-102 midpoint lesson, stint-sized).

Subagent input is the fixer's three-layer architecture transposed
([`fixer-context.md`](fixer-context.md)): **L1** = the versioned
[`agents/jail-subagent-card.md`](../../agents/jail-subagent-card.md) (the FU-117 "third
context" gap, closed — seat-prepended verbatim, never improvised); **L2** = the decomposition
rules accumulating in the [miss ledger](../spikes/subagent-handover-misses.md) (per-class
briefs crystallize only when a class recurs — the ≥2-pattern rule); **L3** = the seat
(slot-by-size, brief-by-class, stated in the dispatch prompt). The fixer discipline that
imports unchanged: **the chunk prompt is self-contained** — the seat injects platform facts
like an issue author would; a subagent hunting for design intent is the context-poverty
failure the A/B watches for.

## The claim-knob ledger (AgentStack, target shape)

The principle: **the claim stops naming models and starts naming constraints** — everything
selection-shaped moves behind `/route`.

| | knobs |
|---|---|
| **Removed** | `workerModel`, `workerModelFallbacks`, `coordinatorModel`, `reviewer.goalModel`, `subscriptionFallback` (the ladder subsumes M12's special case), `fixer.claudeTier` (below), `fixer.guardrail` (incoherent without a fixed chain — per-session caps + rail budgets bound spend), `prober.model`. `routerMode` survives only as the per-stack migration flip and is deleted last. |
| **Kept** | `modelDeny` (entries migrate to FU-127's structured `{rail, model}`), `fixer.budgetUSD`/`resetInterval` (the OpenRouter-rail standing ceiling), and everything that was never model semantics: `docker`, `egress`, `storage`, `labels`, `argo`, `mainRepo`, `coordinator.enabled`, `reviewer.enabled`, `loop.*`, `repos[].fixer`-presence as the dispatchability predicate (IAC-T03). |
| **Added** | `rails:` — allowed-rails list per stack (or per class): the M12 independence ruling as declared policy (platform fix-class = `[anthropic-subscription]`), and a stack's Go opt-out. `classPolicy:` — per-stack class→band/floor overrides, the ONE seam replacing every per-role model knob. Per-rail **budgets** (`openrouter:` USD · `opencodeGo:` usage-value · `subscription:` window-share) — the #278 rail-aware charter's claim surface. |

### The cost rethink & subscription fair scheduling (operator direction, 2026-08-13)

**Tracked by:** FU-180 (subscription budgets + window shares — the build pointer).

`guardrail: only-free` is a legacy of the single-rail era — built to stop a stack silently
moving from free to paid OpenRouter models, when "cost" meant one thing. The landscape it
guarded no longer exists: two subscriptions (Anthropic, Go) whose marginal cost is ~0 but whose
CAPACITY is scarce and shared, free tiers on BOTH API rails, and window-draw that is not
dollars. Three directions replace it (they refine the ledger's per-rail `budgets:` row):

1. **"Cost" becomes rail-typed.** USD (paid API) · window-draw (subscriptions, per-window) ·
   free (rate/reliability-bounded, not money-bounded). The M11 ladder already orders on true
   marginal cost; budgets and reporting follow the same typing (the #278/FU-131 rail-aware
   summation is this direction's accounting half).
2. **`budget: 0` = "subscriptions only" as a first-class stack posture** — spend no NEW money,
   ride only pre-paid capacity (either subscription, both windows permitting). This subsumes
   what `guardrail: only-free` actually protected (no silent paid spend) without lying about
   free-model quality being the point. `only-free` retires with the guardrail knob (ledger
   §Removed) once this exists; the FU-024 enforcement machinery becomes the budget-typed
   refusal.
3. **Subscription capacity gets FAIR SCHEDULING with PLATFORM-owned priorities — as
   WORK-CONSERVING WINDOW SHARES** (operator refinement, 2026-08-13). Not token budgets
   (meaningless across models): the provider's OWN windows are mapped into our system as
   per-stack fractions — e.g. platform 30% of the 5h window, oracle-fleet 20% — declared in a
   platform-side weight table (**homelab's knob, never the stack's**: a stack cannot rank
   itself; cross-stack allocation is platform policy, the CODEOWNERS asymmetry). **Shares are
   caps only under CAP PRESSURE** — the cgroup-shares/WFQ semantic: when the window is idle, a
   1%-share stack may spend 100% of it; the admission predicate engages only when the window
   itself is under pressure (utilization past a pressure floor, or competing deferred demand
   present), and then bounds each stack to share × window with idle shares borrowable. The
   proxy's capacity gates generalize from boolean latch to this weighted admission.
   **Window structure conveniently aligns across rails**: Anthropic 5h/7d, opencode 5h/7d
   (+ its extra 30d) — the share table applies per window and the BINDING window governs
   (M11's language). **Attribution asymmetry to build for**: Go draw is fully self-metered
   per request (chunk B — its ledger must carry the STACK dimension from day one); Anthropic's
   window TRUTH is the global utilization headers, so per-stack draw there is self-metered
   attribution reconciled against header truth. Better stack knobs (posture, budgets, rails),
   better homelab knobs (shares per window), one scheduler.
4. **Budgets meter TOTAL cost — every role, every rail (operator, 2026-08-18).** A Goal budget
   that counts only worker spend INVERTS the incentive: a $0.03 worker round that draws a ~$1
   review round bills as cheap, so the "optimal" composition under worker-only accounting is to
   ship incorrect code and let the reviewer effectively author the fix across CHANGES_REQUESTED
   rounds — the most expensive composition the platform has, invisibly. Only total cost gives the
   right incentive; ROUNDS_MAX bounds the worst case but never prices it. Already measured, three
   ways: Go-rail review rounds ≈$1 each with a 6-round PR cycle the biggest single window draw
   (TICK-LOG 2026-08-13); circles#57's worker rounds cost $0.03–0.05 while the review loop they
   drew was the real spend; goal #278's registry join read **$0 spent** while ~21 coordination
   sessions billed the pool unmeasured (the FU-165 pilot's cadence finding). Build consequences:
   reviewer/coordinator session costs gain the same (stack, issue/goal) attribution keys the
   worker's `agent_run_cost_usd` already carries (the OTLP `claude_code_cost` data exists,
   unattributed today), typed per rail per direction 1; the goal registry's spend join widens
   from worker rows to the full role set; and a child's budget reservation prices the EXPECTED
   WHOLE CYCLE (ride + review rounds + closeout), never the worker cap alone.

5. **Everything gets a dollar amount, and the operator is a RAIL (operator direction,
   2026-08-31 — the r2-F4 correction: a fix priced in reviewer rides optimized the cheapest
   resource on the board while the jail line read $2.55K/wk and the operator's hours went
   unmeasured).** The full price list, most expensive first:
   - **Operator time: €100/h with BATCH-ENTRY semantics.** An interaction costs
     `E/B + minutes×(100/60)` — E ≈ €17–25 is the fixed sit-down cost (keyboard, monitor,
     context reload), amortized over the B items handled in that sitting. Consequences that
     become arithmetic instead of doctrine: an out-of-sitting summons (lone escalation, alert
     pair, single park) bills a full E ≈ €20–30 even for a "30-second" click; a batched
     codeowner read bills €3–8; assembly/theme concentration of N reads saves (N−1)×E; noise
     reduction (FAMINE dedup, asks-are-claims, BLOCKPARK ordering) is rail-1 work with real
     euros attached. The measurement side exists: hands-on hours from the synced jail session
     data (the operator's claude-time method), touch-counts from codeowner-merge/escalation
     events by the operator identity.
   - **Paid API: billed dollars** (exact, harvested).
   - **Subscription draw: THREE prices, each answering its own question** — marginal (≈$0
     under headroom; the M11 ladder's routing input, unchanged), cash-amortized (monthly fee ×
     share of the binding window drawn — the steady-state per-ride cost and the
     portfolio/second-subscription question), and API-equivalent (list × tokens — the
     cross-rail routing comparison and the saturation-displacement value; the Go meter
     computes this natively, the Anthropic half needs tokens×list over the OTLP data).
   Consumers, in adoption order: the retro brief's expected-saving column (BRIEF.md carries
   the ranking rule), seat/design decisions (priced by hand from this list), and eventually
   the M8 feed-4 job pricing, whose expected-cost formula gains the
   `p(operator_touch) × (E/B + item)` term. The `Budget:` line's currency stays USD; a goal
   whose real spend is operator sittings is priced honestly only under this direction.

   **⚖ ROI sequencing (operator, 2026-09-01 — measured on the `agent-cost` Grafana board,
   trailing 7d):** worker $ = **$9.18** fleet-wide (platform included, riding OpenRouter
   deepseek) against **$3.13K** coordinator+reviewer subscription-equivalent over the range
   (jail seat included) — a ~340× ratio. Worker cost is the platform's CHEAPEST line item,
   so tokens spent on finer worker-side counting have no ROI — do not build there. Until Goals meter coordination + review cost (this
   direction's build), the `Budget:` line optimizes the wrong thing; the count caps
   (ROUNDS_MAX and siblings) therefore REMAIN the loop control, and the banked
   caps-become-judgment-triggers / budget-becomes-the-hard-bound reframe (TICK-LOG
   2026-09-01) is gated behind this attribution landing — never relaxed ahead of it. The
   retro follows the same arithmetic: reviews cost more than worker rounds, so its
   cost-model ranking (PR#1127) points it at the expensive half, and its priority target is
   STACK goals (the FU-058 flip, same ruling).

Build home: a later wave of #420 (after the reviewer failover ships); the accounting half
rides #278/FU-131. Nothing here changes chunk A–F scope — the only-free interaction stays the
explicit conservative deny until budget-typing lands.

**`claudeTier` is deprecated** because both its jobs dissolve: harness-from-string dies with the
uniform harness, and the per-ns `claude-session` secret render becomes platform-unconditional —
or better, rail credentials resolve at the proxy by namespace identity (the git-token broker
pattern), leaving **no per-ns LLM secret at all**. The two-part model string (`claude/haiku`,
`openrouter/vendor/model`) survives only as legacy input to `model_id.py`; the routed RESPONSE
(`{rail, model, …}`) is the semantic carrier (FU-127's structured form — a third string segment
like `claude/anthropic/haiku` was considered and rejected: it would be a second grammar to
migrate through).

## The OpenCode Go rail — probed facts (2026-08-13, wallet key `opencode-go-api-key`)

> **POSTURE RULED (operator, 2026-08-25 — pinned on homelab#778):** Go serves
> **janitorial/low-cache roles + failover backup, permanently** — window-draw at list-on-raw
> prices cache-heavy work out (§M8 feed-4's rail affinity, measured: Go review rounds ≈$1 vs
> OR-flash worker rides $0.03–0.05); deepseek+OpenRouter stays the economical worker ride. The
> best find of the rail saga is the ZEN sibling's **big-pickle as deepseek's $0 shadow** (A5
> shadow re-reviews homelab#923, the G-E fan-out arm; matrix row has the caveats). FU-181 holds
> the post-reset hygiene legs; the P4 flip is DE-GATED from Sep-13 by the same ruling.

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
  takeover), while glm-5.2 422s every function tool (deepseek-* 403'd too until the
  China-hosting workspace opt-in was toggled — both pass post-toggle, matrix §quirks). Two
  quirks stay normalized in the jail shim: string-shorthand message content (glm drops it;
  blocks form fine) and claude-code's `?beta=true` + `anthropic-beta` decorations (422).
- **Metadata surface (probed 2026-08-13): registry-POOR.** `/v1/models` returns ids only — no
  pricing, no multipliers, no quota API ("track your usage in the console"; docs admit "for some
  models, their usage multiplier is lower" with NO numbers — the actual multipliers appear only
  in the opencode client's picker: DeepSeek V4 Flash and GPT-5.6 Luna show "(2x usage)").
  ✅ **"Nx usage" RESOLVED for billing (console dump 2026-08-13): billed Cost = list price ×1
  for every model, badged included** (flash exact-list, luna ≈list; worked rows in the matrix) —
  window accounting builds on list prices. The limit-side effect is community-confirmed
  FAVORABLE (the operator's half-off reading, r/opencode ×3): badged models draw the windows at
  HALF their billed list-$ — flash's effective window cR ≈ $0.0014/M. Unverified at the limit
  boundary; the tell = a badged model NOT latching when billed $ predicts it. Detail + the derived qwen3.5-plus rates:
  [`../spikes/opencode-model-matrix.md`](../spikes/opencode-model-matrix.md).
  Contrast OpenRouter's models/endpoints/generation APIs + MCP: the Go-rail registry must be a
  **curated snapshot** (the §M8 gated-data pattern) — docs pricing table + picker multipliers +
  our own per-model canary matrix — with windows self-metered from per-request usage.
- **The Zen sibling**: the same key reaches `…/zen/v1` — opencode's pay-per-token GATEWAY (60
  models incl. `claude-*`; never route claude there — the Anthropic subscription exists) with a
  **free tier**: `deepseek-v4-flash-free`, `mimo-v2.5-free`, `hy3-free`, `nemotron-3-ultra-free`,
  `nemotron-3.5-lightning-free`, `laguna-s-2.1-free`, `big-pickle` — a candidate rung-0 on this
  rail (mostly the same models as the OpenRouter free rung). Tool-compat UNPROVEN (first probes
  400) — canary before any slot use.
- **Slot economics (curated 2026-08-13, revised same day post-opt-in + console billing; unit =
  1M cacheRead + 100k output, the subagent shape):**
  **deepseek-v4-flash ≈ $0.031 — the pick: cheapest priced tool-caller on every axis, billed at
  list ×1 (console-verified), tools ✅ post China-opt-in — PROMOTED to haiku slot + subagent
  default** (the earlier "region-locked, out regardless of math" verdict was the un-toggled
  workspace gate, matrix §quirks) · qwen3.5-plus ≈ $0.13 (rates DERIVED from console billing —
  in $0.25/M, cR $0.025/M, out ≈$1/M; the prior slot holder) · mimo-v2.5 ≈ $0.031 on paper but
  tools 400 on the compat path · qwen3.7-plus ≈ $0.20 · qwen3.8-max ≈ $0.85 · glm-5.2 ≈ $0.70
  (tool-broken) · kimi-k3 ≈ $1.80 (sparse big calls only) — against $12/5h·$30/wk·$60/mo
  usage-value windows (measured 2026-08-13: a full day of probing + canaries + two sessions ≈
  **$0.09**). Next probe: kimi-k2.7-code ($0.19/M cached, 1×) as a mid-tier candidate.
- **Consequence: the Anthropic⟷OpenAI translator is OPTIONAL, not critical-path** — it only
  widens the model set beyond the tool-verified trio. What replaces it on the critical path is the
  maintained **per-model tool-compat matrix** —
  [`../spikes/opencode-model-matrix.md`](../spikes/opencode-model-matrix.md) (the rail-canary
  shape): a Go model enters a slot only after its `tool_use` round-trip passes there. First Go-served subagent ran 2026-08-13
  (~14:45Z, qwen3.5-plus; OTLP-confirmed `query_source=subagent` with zero Anthropic draw).

## Jail tooling (the working prototype — shipped PR#409/#410 + claude-jail)

`scripts/claude-model-shim.py` (local rail split: route by body model id, credential per rail,
oauth never crosses to Go — self-tested + live-proven) · `scripts/claude-go.sh` (claude-or
pattern; slot map from gitignored `.opencode-go.env`, operator-set 2026-08-17:
haiku→deepseek-v4-flash, sonnet→kimi-k3, opus→qwen3.8-max, subagent default
deepseek-v4-flash; main model — fable — stays subscription; `CLAUDE_GO_ALL=1` for pure-Go.
Takes effect at the next `claude-go` launch, which also picks up the chunk-G gometer —
jail Go burn self-meters from there) · claude-jail alias `homelab-go` (upload port 8012). The shim is
deliberately the M11 rail-split shape so lessons transfer to the proxy.

## Preconditions before the fleet flip (acceptance criteria)

1. ✅ **Requested≠served belt — LANDED 2026-08-19** (PR#573, fixes #515; an overnight fixer
   ride): the deterministic drift check joining the launcher's requested model to the served
   model, with `RouterRunModelUnverifiable` as its own coverage alert (unverifiable runs are
   surfaced, never silently passed — first firings are the belt's teething, homelab#577 covers
   its self-test gap). PR#407's class was visible for 6 days in data already collected; alias
   remapping per ride made silent drift MORE likely, which is why this went first.
2. **Rail-aware accounting** — `AGENT_RAIL` folded into stats/`run_reports` (M12's
   declared-unconsumed surfaces), then #278's summation across three currencies (window-draw /
   usage-value / USD). FU-131's sweep relates.
3. **A rail-probe canary per (model, class) cell on the Go rail** (§M7 leg 3 machinery) before
   fleet exposure — compat fidelity is per-model, as the glm shorthand bug showed.
4. **P4-flip evidence** — the shadow ladder read with real urgency data (the caller gap closed
   2026-08-13, PR#408: labels + work-branch urgency now ride `/route` bodies).
5. **Per-role flip discipline (FU-188, 2026-08-26):** any flip of a role-carrying knob
   (`routerMode`, chainless) ENUMERATES the roles it arms, and each role's authoritative path
   has ≥1 exercised run before the flip — the chainless stack flips promoted the reviewer de
   facto on worker-only evidence, and its authoritative branch premiered in production on
   three stacks (the review plane died silently:
   [`../incidents/2026-08-26-reviewer-404-loop.md`](../incidents/2026-08-26-reviewer-404-loop.md)).
   Shadow soaks are read per (role, lane) against the flip that arms them, never as a fleet
   divergence rate.

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
   case-maps, `REVIEW_GOAL_MODEL`, `GOOSE_MODEL` threading, and the retired
   `ROUTER_STRIKE_ENFORCE` read + filter branch (ruled 2026-08-23, §M1a) — each deletion site
   is already named in its own doc. **Sweep additions + the ONE trap (goal #775 findings-store
   entry 5, surfaced here so the sweep session needs no graph read):** three post-wiring
   `--fallback` literals ARE sweep targets (`--fallback sonnet` on the responder + dispatch-unit
   launchers, `--fallback "$MODEL"` on retro), but the `case "$rail" in opencode-go/*)`
   short-circuit blocks in the two Argo lanes are **FU-088 dual-rail latch logic that must
   SURVIVE the sweep** — they look exactly like an M10 case-map and are not one (PR#788
   restored them after a review round dropped them once already).

## Related

ADR-107 (decision record) · [`model-routing.md`](model-routing.md) §M8–M13 (mechanism home; M11
generalizes, M12 folds in) · [`agentstack.md`](agentstack.md) (claim) · FU-095 (routing program
pointer) · FU-127 (structured `{rail, harness, model}`) · FU-131/#278 (accounting) · FU-168
(dispatch throughput) · the banked tier-thesis revision (TICK-LOG 2026-08-13 — review leverage =
decorrelation + tool-grounding, not tier; feeds class policy when piloted).

## Rollout status (2026-08-13)

**2026-08-17 — the platform Go-flash dogfood (operator direction).** Go subscription scope
narrowed to FLASH-ONLY initially ("see how the monthly cap holds up"; Luna reserved pending the
#448 translator — its Anthropic-compat surface is broken even for text, matrix row). Worker
plumbing shipped (PR#458: `opencode-go/*` parser rail, full-id run cmd, `/opencode-limit` gate,
`rail=opencode-go` labels; rung-1 canary clean same day — tool loop through the proxy Go leg,
cache-read shape confirmed). The PLATFORM claim flipped to `workerModel:
opencode-go/deepseek-v4-flash`, fallback `claude/haiku` — deliberately amending the M12
independence ruling as a TEMPORARY dogfood (platform has the most issue traffic → fastest
metrics; reverts to haiku once stack chains ride Go flash). Oracle/sleep chains untouched;
circles folds in at the role-wiring leg. Reviewer failover model = qwen3.5-plus (PR#457 — a
flash failover would review flash-authored code; decorrelation wins). **Same-day follow-through:**
the #448 OpenAI-surface translator SHIPPED after all (PR#465, LiteLLM SDK leg in the jail shim —
luna's Anthropic-compat surface is broken even for text, matrix row; build-order item 1's
"returns to backlog only if the working set proves too narrow" fired); Go window accounting
FIXED (PR#481 — epoch-anchored bounds 5h=daily-grid:217m / 7d=Mon:00Z / 30d=day-13:11:30Z,
window-DRAW pricing; a false 81% weekly latch and a ~30× under-count both traced to rolling
windows + cache-assuming prices; meter now console-exact after calibration rows); the Go
**concurrency semaphore** landed (PR#484, FU-170(a), `OPENCODE_MAX_RUNNING=5`); and
`opencode_subscription_reset_timestamp_seconds` + the two-row parity dashboard shipped
(PR#483, uid `claude-subscription` → "Agent subscriptions — headroom").

**Chunks A–D shipped/live** (PR#429/#433/#434/#435/#436); two live-DOA defects in the leg, both
stub-invisible, both matrix-predicted, both caught only by seat post-merge probes: (1) no
User-Agent on the Go allowlist → Cloudflare 1010 on every live request; (2) the inbound surface
path joined verbatim → opencode.ai's SPA 404 served as 200 HTML (and the self-test had pinned
that join). First organic Go-served review: PR#437 (kimi-k3, input snapshot recorded to the
transcripts bucket). Weekly latch back at 0.95 with the failover carrying latched weeks. Meter
scope: cluster-dispatched only until #438 lands (jail self-metering + push per
[ADR-108](../adr.md)).

**Part 1's FIRST closeout ran 2026-08-19 (#420 — the stint-ritual pilot; the container stays
OPEN in its post-originals phase, operator correction same day: #540 is a post-originals BUG
sprout in the stint's own deliverable, so it binds and holds the parent).** E–H all shipped
in the 2026-08-14 completion wave (PRs #440–#443; E = time-travel re-review via
`agents/re-review.sh`, G = the ADR-108 gometer, H = automatic-role failover with coordinators
staying latched by ruling), #439 leg 2 (#528) merged, and flip-acceptance 1 landed 2026-08-19
(the list above). Bound at closeout: homelab#540 (the gometer 5h-window anchoring bug — the post-originals
sprout that keeps #420 open until its final closeout). Outside the container: the post-reset
sonnet re-reviews (fired at closeout, complete same day), flip-acceptance 2–4, and the
FU-170/FU-171/FU-172 residues on their own tracker items.
