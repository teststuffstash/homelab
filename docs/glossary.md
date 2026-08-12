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
| **Goal** (capital, issue type) | ADR-102's funded container: `task/goal` label + one machine-parsed `Budget:` line, decompose → assembly → post-launch → human verdict terminal | [`agents/issue-authoring.md`](agents/issue-authoring.md) §The goal container |
| **mission** (research) | the research-lane dispatch unit — prepares the contract a Goal then implements. ⚠ Its dispatch label is still `goal` (historical); prose says *mission*, never "research goal" | [`agents/research-and-specs.md`](agents/research-and-specs.md) |
| *goal (prose)* | ⛔ retired in agents docs — say **Goal** (the type), **mission** (research), or "intent/target" in plain prose | — |
| **lens** | the reviewer machinery × a brief sourced from an EXTERNALLY MAINTAINED standard, selected by a deterministic artifact-class predicate. Not a role; not a prose "viewpoint" | [`agents/roles.md`](agents/roles.md) §Lenses |
| **canary** (unqualified) | the scout's **rail probe** — does a model complete a tool-call loop through OUR stack; a verdict about a (model, harness, class) CELL | [`agents/model-routing.md`](agents/model-routing.md) §M7 |
| **⚓ contract probe** | the FU-102 prober's live product-contract check (was informally "agentic canary" — say contract probe) | [`agents/roles.md`](agents/roles.md) §prober |
| **class** (routing) | a task class — deterministic label/role lookup selecting a pool + floors; never inferred in the data plane | [`agents/model-routing.md`](agents/model-routing.md) §M8 |
| **pool** | a scout-curated, ranked, family-deduped model list per class, versioned; drawn by `slot`, never computed at request time | [`agents/model-routing.md`](agents/model-routing.md) §M13 |
| **band** | a disjoint-by-convention curation tier across pools: `regular` / `premium` / `ultra` / `instrument` | [`agents/model-routing.md`](agents/model-routing.md) §M13 |
| **⚓ the Cloudflare admin token** (Tier-0 mint-root) | ONE credential, four aliases: matrix row "Account admin", CF template name "Create Additional Tokens", doctrine name "Tier-0 mint-root". Scope = user `API Tokens: Write` + zone/account read — *transitively* everything | [`cloudflare.md`](cloudflare.md) §Token matrix; creation/renewal: `tofu/cloudflare-token/README.md` |
| **webservice** (operator term) | the delivery contract ONLY — browser-rendered, valid TLS, bookmarkable `<name>.teststuff.net`. No live-vs-static claim; implementation defaults to a generated static page (Garage web endpoint + LAN HTTPS name) | `CONTEXT.md` §Standing constraints (the pin); serving seam: [`garage.md`](garage.md) §Static-website serving |
| **homelab (repo)** | `teststuffstash/homelab` — this repository | `README.md` |
| **⚓ the platform stack** | the AgentStack claim named `platform`: {homelab, agent-runtime, agent-coordinator, openrouter-operator}. ⛔ never "homelab" — sense-1 scoping of a sense-2 duty left 5 agent-runtime issues unswept a month (2026-08-08). Duties scope by the CLAIM's repo list | [`agents/agentstack.md`](agents/agentstack.md); mirror `agents/stacks.json` |
| **the homelab** | the physical lab / the cluster+network as a whole | `CONTEXT.md`, `ARCHITECTURE.md` |
| **findings store** | ADR-106's one typed machine comment per Goal — harvest APPENDS findings (origin, surface, class, substance), a count-keyed marker tracks disposition; checkpoints consume it, never 1:1 issue mints | [`agents/issue-authoring.md`](agents/issue-authoring.md) (v1.2 build) |
| **retro** (cluster) | the platform's batched self-improvement role — ledger worst-K → transcript slices → report + process PRs, Mondays | [`agents/observability-and-retro.md`](agents/observability-and-retro.md) §B2 |
| **skill-retro** (jail) | the jail twin of the retro for `.claude/skills/`: dialogue-only transcript slices → GAPS ledger sightings (ADR-105) | `.claude/skills/skill-retro/SKILL.md` |
| **⚓ system testing** | logic against real components in kind (Garage + app + Grafana + Playwright — the ADR-082 shape) | [`agents/model-routing.md`](agents/model-routing.md) §terminology ruling (2026-07-27) |
| **e2e** | reserved for the ACTUAL target environment (synthetic production traffic) — not the kind gate | same ruling |

## Pending renames (recorded here, executed by the FU-163 sweep)

- The researcher's dispatch label `goal` → a mission-shaped label (machinery touch: scan +
  Sensors + recipes — do NOT rename the label ad hoc; it is read by predicates).
- Prose "goal" rewording — scope re-measured SMALL 2026-08-11 (FU-163: the dense files are
  correct TYPE vocabulary); ambiguous-prose rewords only, at docs-cleanup pace.
