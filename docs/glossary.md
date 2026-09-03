# Glossary — term → one meaning → owning doc (FU-163)

The docs went "stale by addition": terms coined informally were later reused as TYPES, making
the two senses ungreppable apart. This file is the term→home index — **one meaning per term,
each collision listed with its ruled replacement**. Consumers: the `/design` skills' term-closure
step (chase a load-bearing term's owning doc via this index), and `docs-graph-lint` check #3
(a doc leaning on a term without linking its home — buildable now that this file exists).

**The rule that keeps it working** (the prior-art rule applied to naming): **a NEW name for
platform functionality must clear this glossary first** — if the concept exists, use its term;
if the term exists with another meaning, pick a different name. Add the row in the same commit
that coins the name.

Meanings are one line and a pointer — the owning doc keeps the mechanism (one home per fact).

**⚓ = mechanically linted** (docs-graph-lint check #3, warn-only shadow for now): a living doc
using a ⚓ term must link the term's owning doc — or this glossary — somewhere in the file.
Only distinctive terms carry the anchor; common words (goal, lens, canary, class, pool, band,
mission) would drown the check in false positives and stay judgment-lint territory.

## Ruled terms

| Term | Meaning | Owning doc |
|---|---|---|
| **Goal** (capital, issue type) | ADR-102's funded container: `task/goal` label + one machine-parsed `Budget:` line, decompose → assembly → post-launch → human verdict terminal | [`agents/issue-authoring.md`](agents/issue-authoring.md) §The goal container (consumer card at the top of that section — authoring needs nothing else) |
| **mission** (research) | the research-lane dispatch unit — prepares the contract a Goal then implements. Carries NO label today (the legacy `goal` label is gone and never had a machine reader — FU-163, resolved 2026-08-23); **`mission`** is the reserved dispatch-label name for when FU-090(c) graduates | [`agents/research-and-specs.md`](agents/research-and-specs.md) |
| *goal (prose)* | ⛔ retired in agents docs — say **Goal** (the type), **mission** (research), or "intent/target" in plain prose | — |
| **lens** | the reviewer machinery × a brief sourced from an EXTERNALLY MAINTAINED standard, selected by a deterministic artifact-class predicate. Not a role; not a prose "viewpoint" | [`agents/roles.md`](agents/roles.md) §Lenses |
| **canary** (unqualified) | the scout's **rail probe** — does a model complete a tool-call loop through OUR stack; a verdict about a (model, harness, class) CELL | [`agents/model-routing.md`](agents/model-routing.md) §M7 |
| **⚓ contract probe** | the FU-102 prober's live product-contract check (was informally "agentic canary" — say contract probe) | [`agents/roles.md`](agents/roles.md) §prober |
| **class** (routing) | a task class — deterministic label/role lookup selecting a pool + floors; never inferred in the data plane | [`agents/model-routing.md`](agents/model-routing.md) §M8 |
| **pool** | a scout-curated, ranked, family-deduped model list per class, versioned; drawn by `slot`, never computed at request time | [`agents/model-routing.md`](agents/model-routing.md) §M13 |
| **band** | a disjoint-by-convention curation tier across pools: `regular` / `premium` / `ultra` / `instrument` | [`agents/model-routing.md`](agents/model-routing.md) §M13 |
| **⚓ the Cloudflare admin token** (Tier-0 mint-root) | ONE credential, four aliases: matrix row "Account admin", CF template name "Create Additional Tokens", doctrine name "Tier-0 mint-root". Scope = user `API Tokens: Write` + zone/account read — *transitively* everything | [`cloudflare.md`](cloudflare.md) §Token matrix; creation/renewal: `tofu/cloudflare-token/README.md` |
| **api** (PublicRoute profile) | the machine-facing route class: per-IP rate limiting ON (threshold = claim field, platform default 1200/min, bounds 60–6000), NO challenge-shaped mitigations reach the route, structured 429 on limit, CORS/preflight edge-owned via claim fields. ⛔ never "API route" in prose — say **api-profile route** | [`cloudflare.md`](cloudflare.md) §PublicRoute — Built mechanism |
| **consumer** (PublicRoute profile) | the browser-facing route class: edge caching defaults on (respect-origin; Cloudflare default TTL when the origin sends none), RUM/client telemetry rendered (⚖ no scoped-token write permission for Web Analytics exists — live status in cloudflare.md), challenges legal. ⛔ never "consumer route" in prose — say **consumer-profile route** | [`cloudflare.md`](cloudflare.md) §PublicRoute — Built mechanism |
| **webservice** (operator term) | the delivery contract ONLY — browser-rendered, valid TLS, bookmarkable `<name>.teststuff.net`. No live-vs-static claim; implementation defaults to a generated static page (Garage web endpoint + LAN HTTPS name) | `CONTEXT.md` §Standing constraints (the pin); serving seam: [`garage.md`](garage.md) §Static-website serving |
| **homelab (repo)** | `teststuffstash/homelab` — this repository | `README.md` |
| **⚓ the platform stack** | the AgentStack claim named `platform`: {homelab, agent-runtime, agent-coordinator, openrouter-operator}. ⛔ never "homelab" — sense-1 scoping of a sense-2 duty left 5 agent-runtime issues unswept a month (2026-08-08). Duties scope by the CLAIM's repo list | [`agents/agentstack.md`](agents/agentstack.md); mirror `agents/stacks.json` |
| **the homelab** | the physical lab / the cluster+network as a whole | `CONTEXT.md`, `ARCHITECTURE.md` |
| **⚓ findings store** | ADR-106's one typed machine comment per Goal — harvest APPENDS findings (origin, surface, class, substance), a count-keyed marker tracks disposition; checkpoints consume it, never 1:1 issue mints | [`agents/issue-authoring.md`](agents/issue-authoring.md) (v1.2 build) |
| **retro** (cluster) | the platform's batched self-improvement role — ledger worst-K → transcript slices → report + process PRs, Mondays | [`agents/observability-and-retro.md`](agents/observability-and-retro.md) §B2 |
| **skill-retro** (jail) | the jail twin of the retro for `.claude/skills/`: dialogue-only transcript slices → GAPS ledger sightings (ADR-105) | `.claude/skills/skill-retro/SKILL.md` |
| **⚓ Go rail** (opencode-go) | the OpenCode Go subscription as a billing rail — usage-value windows ($12/5h·$30/wk·$60/mo), OSS models, Anthropic/OpenAI-compat endpoints; model ids prefix `opencode-go/` | [`agents/chainless-redesign.md`](agents/chainless-redesign.md) (ADR-107 charter) |
| **⚓ Zen rail** (opencode) | the OpenCode Zen FREE tier as the jail's third rail (issue #444) — model ids prefix `opencode/`, same wallet key as the Go rail, metered $0 by operator direction (assumption sentinel: a bare id that doesn't end `-free` and isn't `big-pickle` warns) | the jail shim routes it (`scripts/claude-model-shim.py`); the free-tier models register in [`spikes/opencode-model-matrix.md`](spikes/opencode-model-matrix.md) §OpenCode Zen free tier |
| **board** (operator view) | `devbox run board [-- <stack>] [--full]` — the deterministic who-acts todo view (REVIEW / FIX / SOLVE / TRIAGE / VERDICT DUE / BACKLOG-aggregate); a retrieval tool, never a corpus sitting. Not the janitor (LLM board *judgment*) | [`agents/issue-authoring.md`](agents/issue-authoring.md) §Label semantics; impl `agents/board.sh` |
| **disposition** (tree member) | the CONTAINER's ruling on a bound child of an epic: `undispositioned` (a wake for the checkpoint, never a block) → `adopted` (scope; counts for completion) or `deferred` (lineage kept, out of scope, movable). Written only by the checkpoint/closeout act, never by the filer — binding is dumb (ADR-122). Distinct from the findings-store's "dispositioned-through" marker, which is the same act one level down | [`agents/issue-authoring.md`](agents/issue-authoring.md) §The lineage contract, rule 9 |
| **epic** | an issue whose native sub-issue tree bounds work through its lifecycle — the shared LINEAGE/LIFECYCLE contract (bind-at-filing, defects-never-release, originals/sprouts, close-at-tree-empty); kinds: **Goal** (ADR-102/106) and **stint**. Explicitly NOT merge or budget mechanics — those are kind rules. ⚠ `task/goal`-keyed machinery is Goal-kind, never assumed epic-general | [`agents/issue-authoring.md`](agents/issue-authoring.md) §The lineage contract |
| **⚓ stint** (jail) | an **epic kind**: the jail lane's bounded work container — a label-inert parent issue (`stint: <slug>`, `Size: N sessions`) whose native sub-issue tree binds all work AND all sprouts; multiple closeouts, first at originals-done (full sweep), parent closes when the tree empties. The Goal SHAPE with none of the Goal machinery — never `task/goal`, never budget-gated. ⚠ NOT "wave" — that word already carries three senses here (ArgoCD sync waves, Z-Wave, the informal subagent-batch usage), the exact stale-by-addition collision this file exists to prevent (operator catch, 2026-08-19) | [`agents/chainless-redesign.md`](agents/chainless-redesign.md) §The jail stint |
| **platform-request** (label) | the capability-request lane (ADR-119): intent-level platform demand filed in the STACK's own repo; pull-only approval, disposition always | [`agents/platform-and-stacks.md`](agents/platform-and-stacks.md) §Cross-stack demand & escalation |
| **`Capability:`** (body line) | the lane's machine fingerprint — an INTENT on a surface (`public-edge.abuse-fairness`), never a vendor/mechanism name (the WAF asymmetry) | same section |
| **⚓ switchboard** | the global `/coordinate` surface (ADR-120): a Sensor-edge RESOLVER — patches repo-dumb rings through to their stack's own doorbell (FU-144) and fans capacity transitions fleet-wide; never scans, never dispatches, no cron. ⛔ not a coordinator — the real coordination is the per-stack loops | [`agents/workflow.md`](agents/workflow.md) §Triggers; impl `agents/coordinator/coordinate-argo.yaml` |
| **⚓ system testing** | logic against real components in kind (Garage + app + Grafana + Playwright — the ADR-082 shape) | [`agents/model-routing.md`](agents/model-routing.md) §terminology ruling (2026-07-27) |
| **e2e** | reserved for the ACTUAL target environment (synthetic production traffic) — not the kind gate | same ruling |
| **registry (first-party)** | the push-mode in-cluster OCI registry `registry.teststuff.net` (ADR-121) — first-party artifacts pushed at release (the ert-corpus class). ⛔ distinct from the pull-through **registry mirrors** (ADR-091, `registry-cache` ns), which proxy upstreams and are never pushed to | `argocd/resources/registry/` (manifest headers carry the design); ADR-121 |
| **diff-ci** | the local pre-flight: `devbox run diff-ci` runs only the CI gates the current diff can affect, from the path→task map in `scripts/diff-ci.sh` — the ONE HOME ci.yaml's skip step eval-extracts its trigger regexes from (#518, flip live 2026-08-31). CI stays authoritative; PR-context gates (pin-only/governance/ratchet) run only there | [`ci.md`](ci.md) |

## Pending renames (recorded here, executed by the FU-163 sweep)

- ~~The researcher's dispatch label `goal` → a mission-shaped label~~ **EXECUTED 2026-08-23
  (S4 #766)**: verified that NO predicate reads a bare `goal` label (the scan keys on
  `task/goal`; research dispatch is operator-manual) and the legacy hand-made labels were
  already deleted by the authoritative IssueLabels sync — so the sweep was prose + this
  glossary; `mission` is the reserved future label name (minted via the claim taxonomy at
  FU-090(c) graduation, never ad hoc).
- Prose "goal" rewording — scope re-measured SMALL 2026-08-11 (FU-163: the dense files are
  correct TYPE vocabulary); research-lane hot-spots reworded with #766; the residue rides
  docs-cleanup pace.
