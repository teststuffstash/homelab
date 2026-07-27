# The -iac lane — no humans in the deploy path (FU-106)

_Design narrative, born 2026-07-27 from the first live -iac fixer dispatch (sleep-iac#28) and the
operator rulings the same day. The machine itself is modeled in
[`iac-lane-fsm.yaml`](iac-lane-fsm.yaml) → generated view [`iac-lane-fsm.md`](iac-lane-fsm.md),
same lint as the app machine. The app-repo merge path ([`merge-path.md`](merge-path.md) /
[`merge-path-fsm.yaml`](merge-path-fsm.yaml)) does NOT apply here — that was the founding
observation: -iac repos are not application repos._

## Why -iac is a different machine

In an app repo, CI carries the evidence (tests, the full-stack gate) — green means *behavior
verified*, `Merged` is the terminal state, and tested-tree==landed-tree is the whole guarantee.
In an -iac wrapper repo that inverts: **CI can only prove FORM** (does it render, does it match
schemas, does it satisfy policy); the behavioral truth arrives *after* merge, as ArgoCD sync →
resource health → SLO/KPI. **Merge is the midpoint of the -iac lifecycle, not the end** — so the
machine has a post-merge half, and that half is the primary gate, not a belt.

## The doctrine (operator rulings, 2026-07-27)

1. **No human in the deploy path.** Nothing a human must click sits between a queued issue and a
   reconciled deployment. The platform enforces budgets (FU-093 quota, `budgetUSD`, resource caps
   like a bucket's `max_size`); user happiness is measured (SLO probes, gateway KPIs); degradation
   rolls back automatically (FU-044 chain). Humans appear **monthly** — the retro (FU-058) + 🌱
   sprout triage, where "is this successful experiment worth its complexity" gets decided — and on
   **product-contract specs** (the codeowner gate, already delegated day-to-day).
2. **Cheap CI validation is still worthwhile.** An assertion in CI costs seconds and *explains
   itself* (a reason/message at the point of failure); the same defect caught post-merge costs a
   revert, an investigation session, and tokens. Deterministic-first is an economic ruling, not
   just a safety one: catch cheap, explain loud, and reserve the post-merge machinery for what
   CI structurally cannot see.
3. **No blocking LLM review either.** The reviewer demotes to an *advisory lens* (IAC-G06): async,
   post-merge, on the cheap grounding tier (the FU-095/retro evidence class — grounding-strong
   models, not coding-strong), filing findings as inert issues. Review becomes evidence
   generation; it never adds latency or subscription draw to the deploy path.

## Lane taxonomy — each PR class gets its own gate

| lane | author | gate | notes |
|---|---|---|---|
| `deploy_bump` | deploy App | CI-only, instant (ADR-084) | `require_approval=false` is deliberate: App bypass can't waive an approval, so it was dropped, not bypassed |
| `infra_enrich` | coordinator unit | rides the bump PR (atomic pin+claim) | mechanical (schema-valid, FU-093 quota) = CI lane; judgment parks (roles.md §infra-fixer) |
| `fixer_issue` | worker | **the gap** (IAC-G01) — closes via the policy sentinel, not review | sleep-iac#28: 38s self-merge incl. `.github/workflows/` |
| `operator` | operator/meta session | CI-only | the directing human IS the review |
| `revert` | FU-044 chain | CI-only, must NEVER gain a gate | the emergency path stays instant |
| `renovate` | Renovate | existing classification (renovate.md) | |

## Assurance layers (what catches what)

- **L0 — CI, deterministic (form):** helm template / kustomize build renders, kubeconform against
  pinned CRD schemas, and **policy-as-code for the platform contract that is already prose**:
  ip-plan ranges (ADR-088), hostname conventions, ADR-076 bucket ownership, tenancy boundaries,
  secret *references-never-values*, `deletionPolicy` guards, workflow-path rules. Every rule kills
  an incident class forever, with a message. This is the decision-table doctrine applied to infra.
- **L0b — the tamper-proof sentinel (IAC-G04):** in-repo CI runs the PR's own workflow code, so a
  required check the PR can rewrite is not a gate against the worker itself. The policy check that
  carries the *security* class runs **cluster-side** (exporter/Argo Events shape), evaluates the
  PR's rendered manifests against homelab-owned rules, and posts a commit status the PR cannot
  touch. This — not review — is what closes IAC-G01, because rollback is structurally blind to
  silent security holes (a public bucket never degrades a KPI).
- **L1 — pre-merge rendered diff:** master-vs-branch manifest diff as a PR comment — grounds any
  reader (human or lens) in the actual delta, catches plausible-YAML-wrong-effect.
- **L2 — post-merge machine:** sync → health → observation window (below) → promote | revert.
  Widened revert trigger (IAC-G02), cluster-verifying closeout (IAC-G03).
- **L3 — runtime:** SLO probes + error-budget teeth (FU-104 — budget burnt already parks the
  stack's auto-merge lane: the platform pausing shipping when users hurt, no human), responder
  routing to the -iac ops surface, scheduled drift/audit lenses (FU-101 shape) for the silent
  classes between policy rules.

What structurally cannot be caught pre-merge: references to platform-precreated resources,
provider-side effects, cross-stack interactions. That is exactly the post-merge half's job, and
why revert-first (never fix-forward-in-place) is the standing play.

## Progressive delivery — the observation window (IAC-G05)

The current platform (ArgoCD + Cilium Gateway API + Argo Workflows/Events + Prometheus — no mesh,
by design) supports three rungs; **eventually Cloudflare fronts all services** (operator,
2026-07-27), which is where the top rung lives.

- **Rung 0 — smoke-verified sync (any stack, buildable now):** an ArgoCD **PostSync hook Job**
  curls the new deployment — `/healthz` plus one real read — so "Synced" only reports after the
  service *answered*, and a failure fails the sync loudly into the existing Degraded→revert path.
  Sleep is the shape-proving pilot: a single user, so the curl IS the user. Zero new components.
- **Rung 1 — in-cluster traffic split:** Gateway API weighted `backendRefs` (Cilium implements
  them; the ADR-092 sleep Gateway is already this stack): stable + canary Deployments, promotion =
  a weight flip driven by a Workflow step reading Prometheus. If/when analysis-driven promotion
  should be declarative, **Argo Rollouts + its Gateway API plugin** is the fit — the
  [README](README.md) §Open "revisit Rollouts only if reality proves testing insufficient" clause
  fires for oracle *differently than written*: not because testing failed, but because runtime
  evidence IS the product's decision signal (the free tier is the canary — the business design).
- **Rung 2 — the edge (Cloudflare, the destination):** key-tier routing at the gateway/Worker
  (free→latest, paid→stable pin), weighted CF Load Balancing across origins, and **shadow
  mirroring** — the teststuff ladder (① shadow ② serve-with-hedge ③ stable). Wrong-answer-with-200
  detection lives HERE (diff candidate vs stable on mirrored real traffic), not in k8s health.
  The cluster rungs stay the reference deployment underneath, per the architecture doc's own rule.
- **Probe placement corollary:** once Cloudflare fronts a service, the SLO probe needs an
  outside-in leg through the same path users take — an all-green LAN probe over a broken edge is
  the FU-108 lesson (a probe that returns cleanly is not a probe that looked) at network scale.

Oracle is where this is the business idea; sleep gets rung 0 now purely to prove the shape.

## Model class — devops is not coding

The -iac task shape is grounding-heavy (schema adherence, cross-referencing platform contracts),
not algorithm-heavy — and the retro program's evidence (FU-058 runs 1+2) says exactly that axis
separates models: deepseek-v4-pro/hy3 graded opus-adjacent on grounded work at $0.02–0.08 while
fabricator-prone models invented APIs precisely where grounding was needed. So: **the -iac lane
gets its own chain**, not the app-coding chain. Mechanism: interim = per-repo override in the
claim (`repos[].fixer.workerModel/[Fallbacks]`, the `dockerRepos` pattern); proper home =
FU-095(a), where **repo-type (app vs -iac) is the first task-class axis** (cheaper and sharper
than budget×track, and the FU-057 ledger already keys per-repo). Rotation entrants earn devops
evidence via a devops-shaped scout canary (render + patch a manifest against a schema) — coding
canaries prove nothing here.

## Build order

Tracked on FU-106; the gap register (IAC-G01..G06) IS the list. Suggested order: G05-rung-0
(sleep PostSync smoke — smallest, proves the post-merge shape) → G02+G03 (revert widening +
cluster-verifying closeout — both homelab-side, small) → G04 sentinel skeleton + first rule set
(closes G01) → G06 advisory lens → rung 1/2 when oracle's gateway metering (T3c) exists.
