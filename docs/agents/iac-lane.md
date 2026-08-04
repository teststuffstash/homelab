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
| `pin_follow` | deploy workflow (**IAC-G07 SHIPPED 2026-08-02**, oracle-fleet#167) | CI-only (pure mechanical) | cross-repo image-ref propagation: workflow tags ride the bump commit, pin-hold opt-out. Was the single most frequent human commit in oracle-iac history (7 of the last 120). |
| `data_roll` | operator (oracle corpus rolls) | paired-roll contract (fleet#159 schema gate) | 4 of the last 120 oracle-iac commits; semi-mechanical since the schema gate — WHICH corpus stays judgment, the paired pin+digest commit is workflow-shaped |
| `operator` | operator/meta session | CI-only | the directing human IS the review |
| `revert` | FU-044 chain | CI-only, must NEVER gain a gate | the emergency path stays instant |
| `renovate` | Renovate | existing classification (renovate.md) | |

## The platform lane — homelab is one repo, so the gate is per PATH

Every stack splits an app repo (behavior; CI carries the evidence) from `-iac` (form + post-merge
truth). **homelab has no such split.** It *is* the platform's own `-iac` — ArgoCD watches
`argocd/`, `agents/coordinator`, `agents/fixer/*` and syncs on merge, so merge is the midpoint here
too — and it is simultaneously where the loop's own machinery lives. So the lane taxonomy above
cannot key on the repo. It keys on the **path**.

| paths | applied by | agent may author | gate |
|---|---|---|---|
| `docs/**` | nothing | ✅ | CI |
| `argocd/resources/**` | ArgoCD — merge *is* deploy | ✅ | CI (see the check-coverage caveat below) |
| `argocd/platform/**` | ArgoCD app-of-apps, `prune: true` | ✅ | **codeowner** — an edit here *deletes* services |
| `tofu/*.tf` (root) | `tofu apply` | ✅ | **codeowner**; apply stays out-of-band (cone rule) |
| `ansible/**` | `opnsense-playbook.sh` → the router | ✅ | **codeowner** + windowed apply |
| `agents/**`, `scripts/**`, `policy/**`, `.github/workflows/**`, `tofu/github/**`, `tofu/cloudflare/**` | governance & supply chain | ❌ **never** | operator only |

Two files are carved back OUT of that table because the arc-runner auto-bump commits both
(`argocd/platform/arc-runners.yaml`, `agents/coordinator/reflexes-argo.yaml`) and a mechanical tag
bump should not wait for a human. Ownership is **replaced, not dropped**: `pin-only-lint` (in the
required `ci`) allows only arc-runner image-pin lines into them via a PR — stricter than the review
it stands in for, since a regex cannot approve a smuggled fourth line. Real edits take the operator
path (direct to master), which is not a PR and not gated. That is the general shape for anything
else that needs un-gating: **replace the owner with a rule, never just remove the owner.**

The deny row is the load-bearing one. `agents/**` holds the launcher that builds its own dispatch
command (ADR-094), the scan that decides what gets dispatched, and the reflex that approves its own
PRs; `tofu/github/**` holds the ruleset governing all of it. **A fixer permitted to edit its own
governor is not gated at all**, whatever the ruleset says.

Two things are missing before homelab can be a fixer target (FU-068):

1. **No CODEOWNERS file exists**, so the gate column has nothing enforcing it. `oracle-fleet`
   already runs exactly this shape (`require_code_owner_review = true`, CODEOWNERS gating `/specs/`
   and `/.agents/`) — homelab is the one repo that never got it.
2. **homelab's ruleset is the permissive one** — `require_approval = false`, deliberately, so
   deploy-pin bumps auto-merge on CI-green ("not a fixer-target", says the comment in
   `tofu/github/variables.tf`). Correct today; the day a fixer authors here it means an agent PR
   lands with no human anywhere in the path.

**Automerge safety is a function of check coverage, not of the path.** homelab's `ci` is
`argocd-validate-pins`: it proves a pinned OCI chart still renders with this repo's values, and
looks at nothing else. Widening the auto tier must land the missing checks first — `kubeconform` /
server-side dry-run over `argocd/resources/*`, `tofu validate`/`fmt`
([`dependency-upgrades.md`](../dependency-upgrades.md) §3 owns that list). Otherwise the ruleset
says "gated" and means "unreviewed".

### ⚖ Auto-revert does NOT generalize to the platform (operator ruling, 2026-08-04)

The obvious next step from FU-044 — point the Degraded→revert chain at homelab's own ArgoCD apps —
is **rejected as a blanket rule**, for two reasons that are properties of the platform rather than
of the mechanism:

- **The platform barely has the trigger.** The chain reverts *"the newest `deploy/*` bump merged
  ≤120m"*. In homelab only the first-party image pins move that way (agent-base,
  agent-coordinator, arc-runner). garage, kube-prometheus-stack, loki and forgejo move by
  chart-version bumps and hand edits — there is usually no `deploy/*` commit to revert to.
- **Revert is not free for stateful services, and this is the last net.** Reverting a garage or
  CNPG chart can be worse than the failure it answers: CRD/schema downgrades, PVC expectations,
  data-layer skew. And if the revert *also* fails, nothing catches it — on a stack that costs the
  stack, here it costs the machinery that would have fixed it.

**Ruling: auto-revert extends to homelab only for the reversible class** — a first-party image
**pin** bump, no CRD/schema migration, no data-layer coupling. Everything else that goes Degraded
reaches the responder as an alert plus a report-only issue, and a human decides. Stated as a
precondition rather than an app list so it survives new apps: *revert automatically only where the
change is a pin and the rollback is provably as safe as the roll-forward.*

### Who owns a symptom — the alert lane vs the observation window

Two entry points reach the same post-merge machinery: **change-triggered** (a merge opens a window,
IAC-T04/T05) and **symptom-triggered** (the responder, IAC-T07). They already overlap in
production — the responder's cheapest-sufficient outcome list includes a GitOps quick fix on the
stack's `-iac`, which *is* this lane's revert path. Undefined ownership means a revert racing a fix.

**Rule: inside an open observation window for a recent deploy, the -iac lane owns the symptom** —
the alert lane attaches evidence to that unit and dispatches nothing. Outside a window, the alert
lane owns it. Modelled as IAC-G10; the correlation half (one issue per root cause via a `subject:`
key, instead of one per fingerprint) is FU-133.

## The infra-delta rollout matrix — what an upstream chart change costs the wrapper

The whole role exists because of the **target-agnostic-chart constraint**
([platform-and-stacks.md §Composition axes](platform-and-stacks.md), 4th bullet): app charts carry
only the consumption **contract** (`values.schema.json`, `existingSecret`, endpoint values,
default-off flags for ecosystem-standard CRDs) and deploy anywhere; **platform fulfillment**
(Crossplane claims, ExternalSecrets) lives in the per-target wrapper chart in `-iac`. So every
upstream change has to be classified by what it demands of the wrapper:

| # | Chart change | What `-iac` must do |
|---|---|---|
| a | New **provisionable** (bucket, key, DB) | Wrapper claim, **atomic with the pin bump** |
| b | New value **with a default** | Nothing — chart default carries it |
| c | New **required** value | The `values.schema.json` **diff between chart versions IS the typed infra delta** → the scan emits one infra unit per `-iac` target dir → the role **enriches** the ADR-084 bump PR (pin + fulfillment in ONE commit = deploy-atomic, the meta-11 paired-rolls rule generalized) |
| d | **Expand/contract** for code-level compat | Both halves, with a scan **aging predicate** on undropped expands (a debt timer; the contract task is born via the FU-090 harvest) |
| e | **Runtime wedge** (`optional: false` → new RS wedges, old keeps serving) | The occasional visible-stall variant of (c) |
| f | **Quota / judgment** | Codeowner-gated, provider-first hold — the only surviving hold |

Mechanical (schema-valid **and** within the FU-093 quota) rides the CI-only auto-merge lane; the
**FU-093 storage ledger is what DEFINES "mechanical"** ([storage-ledger.md](../storage-ledger.md)).
Hard boundary: the role wires secret **references**, never values — Infisical writes stay
operator/ESO-push.

**Greenfield is OUTSIDE this matrix (named 2026-08-02).** The matrix diffs an EXISTING wrapper
against a chart delta; a project's FIRST chart has no wrapper to diff — `values.schema.json`
appearing at all is the delta. That case is a **bootstrap seam, not a lane class**: the first
wrapper is semi-derivable (donor copy from the freshest graduated stack — the FU-070 copy-paste
experiment — plus the schema's required-without-default list as the fill-in worklist, plus the
chart's `example-homelab-values.yaml` as the worked example), but its judgment slots are
irreducibly operator: secret VALUES (the reference/value boundary above), platform precreations
(ns, repos), and the FU-039 subdomain claim. After the first deploy the stack enters the matrix
and evolves via `infra_enrich`.

⚠ This deliberately **re-opens two standing exclusions** — `fixerRepos` context-only (the FU-086
predicate) and "sleep-iac excluded, CI-only deploy repo" — via a *distinct dispatch class*, not by
silently flipping them.

**Built 2026-07-27:** `agents/infra-schema-diff.sh` (the typed delta + `enrichment_needed` bit,
verified); the scan's `ci-red-stale` probe routes a RED `deploy/*` bump PR in a `*-iac` repo to the
distinct `infra-enrich` class — the item session helm-pulls both chart versions, runs the diff, and
enriches **the same PR** (brief §infra-enrich). The sleep-iac exclusion was re-opened deliberately
via a reviewed claim diff (sleep-iac#24: fixer block, stack-declared fixer ns, `-iac` fix.yaml +
PROD-SERVING rubric). First live dispatch 2026-07-27 (#22 → PR#28, merged, deliverables verified by
the C6 closeout) — **and that dispatch is what exposed IAC-G01**, below. The **oracle-iac twin
went LIVE 2026-08-02** (fixer block #262 + ns render; first ride #97→#265 merged clean).

## Assurance layers (what catches what)

- **L0 — CI, deterministic (form):** helm template / kustomize build renders, kubeconform against
  pinned CRD schemas, and **policy-as-code for the platform contract that is already prose**:
  ip-plan ranges (ADR-088), hostname conventions, ADR-076 bucket ownership, tenancy boundaries,
  secret *references-never-values*, `deletionPolicy` guards, workflow-path rules. Every rule kills
  an incident class forever, with a message. This is the decision-table doctrine applied to infra.
- **L0b — the tamper-proof sentinel (IAC-G04): v1 BUILT 2026-08-03, SHADOW mode.** In-repo CI
  runs the PR's own workflow code, so a required check the PR can rewrite is not a gate against
  the worker itself. The sentinel runs cluster-side (`iac-sentinel` CronWorkflow */15,
  agent-coordinator ns, arc-runner image) with rules and engines from THIS repo's master —
  the PR tree arrives as a tarball (data, never executed; no helm/hooks in v1 — raw-YAML pass,
  the render pass is v2). **Engines (operator ruling: no engine sprawl — Kyverno is THE rule
  engine, CLI seat now, the admission-controller seat is its future; NB no prior roadmap record
  of kyverno was found — this ruling is the record):** `policy/iac/*.yaml` (5 Kyverno policies:
  raw-Secret, public-bucket, explicit-Delete deletionPolicy, VIP∈192.168.32.0/19,
  cluster-scoped power kinds — all synthetically verified firing), gitleaks (secret values,
  fleet-standard), and a bash path-rule (worker-authored PRs must not touch
  `.github/workflows/**` — the sleep-iac#28 hole; a GitHub **push ruleset** with restricted
  file paths is the enforcement-grade native version, to verify+tofu at the flip).
  **Shadow → enforce is the router-rollout pattern**: v1 posts nothing to GitHub (logs +
  pushgateway `iac_sentinel_violations`/`_engine_seconds`); the flip adds `statuses: write` to
  the homelab-REVIEWER App (never the worker's own identity — it could pass itself) + a
  required check on the -iac repos.
  **Measured overhead (2026-08-03, both -iac repos at master):** fetch ~0.7–1.0s · collect
  ~0.2s · kyverno ~0.7–0.8s (5 policies × 17–25 docs) · gitleaks ~0.14s · **total ~1.8–2.1s
  serial per PR head**. Parallelizing engines saves <1s while ARC job overhead is ~10–30s and
  the poll tick is 15min — **parallel steps start paying only when serial engine time reaches
  the job-overhead scale (~10s+)**, i.e. after the v2 render pass (helm templating per chart is
  the expensive step) or ~10× policy growth; revisit against `iac_sentinel_engine_seconds` then.
  This — not review — is what closes IAC-G01, because rollback is structurally blind to
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

### ⚠ ArgoCD health is NOT the post-deploy gate (sharpened by meta-11, 2026-07-26)

A chart that renders and passes kubeconform can still break at runtime — a bad migration, a
crashlooping CronJob, a probe that passes while the thing behind it is dead. The meta-11 schema-skew
outage **stayed GREEN in Argo throughout**, because the pods were Ready on a `tcpSocket` probe.

So L2's health check is a *shallow* gate, and two things carry the real weight:

- **The deep contract probe** — the FU-102 prober at tools/call level, "verify through the deepest
  component" ([roles.md](roles.md) §prober). That is the acceptance signal, not app health.
- **The deterministic half of prevention** — the paired-roll / schema-gate contract
  (oracle-fleet#159 shape) plus readiness that actually exercises the backend (#157).

**Deterministic rollback shipped 2026-07-27 (FU-044, no LLM):** argocd-notifications (`oncePer`
revision) POSTs a post-sync **Degraded** app → the `/deploy-degraded` edge → the `deploy-revert`
Sensor/Workflow ([`agents/coordinator/deploy-revert-argo.yaml`](../../agents/coordinator/deploy-revert-argo.yaml)):
it reverts the newest `deploy/*` bump merged ≤120m that touches the app's path, as an auto-merging
PR (branch + cm-ledger idempotency). Non-`-iac`, no-recent-bump and revert-conflict all fail closed
to report-only.

**Roll-FORWARD — dispatch a worker against the app repo to fix the breakage — is the remaining LLM
half.** Direction is settled: do it **in-cluster off ArgoCD app-health events, NOT in the GitHub
Actions deploy run**, since the deploy job now ends at "auto-merge armed" (`deploy-pin.sh`) and
post-deploy health is decoupled from CI. Standing operator prereq: **harden app CI so prod
breakages are rare** — the rollback is the safety net, not the primary control.

## Progressive delivery — the observation window (IAC-G05)

The current platform (ArgoCD + Cilium Gateway API + Argo Workflows/Events + Prometheus — no mesh,
by design) supports three rungs; **eventually Cloudflare fronts all services** (operator,
2026-07-27), which is where the top rung lives.

- **Rung 0 — smoke-verified sync (any stack, buildable now):** an ArgoCD **PostSync hook Job**
  curls the new deployment — `/healthz` plus one real read — so "Synced" only reports after the
  service *answered*, and a failure fails the sync loudly into the existing Degraded→revert path.
  Sleep is the shape-proving pilot: a single user, so the curl IS the user. Zero new components.

  **Cron-shaped apps (⚖ answered 2026-08-03, built as sleep-tracking#113):** a CronJob has no
  endpoint to curl — its `/healthz` is **a run's exit code**. The hook Job runs the app for real
  (init step, same podTemplate) then does **freshness-free read assertions** on the output (opens,
  non-empty, newest record plausibly recent). Two operator rulings baked in: (a) *no
  run-freshness assert* — upload-on-unchanged-input is incidental behavior today, and such
  behaviors become contracts only after the pattern emerges across multiple projects, not
  per-app; (b) *real-run-as-hook presumes runs are idempotent and cheap* (true for sleep's
  small dataset). For a future cron where reruns are costly or side-effecting, the candidate
  shapes are: a **dry-run/smoke flag** in the app (parse config + touch dependencies, write
  nothing), a **data-subset canary** (new logic gated to a slice of ids/tenants via flag —
  rollback = flag flip), a **parallel shadow CronJob** (new image against a clone/validation
  pool, compare outputs), or **phased schedule frequency** (canary runs 1×/day before the image
  lands on the real cadence). Pick per app; none needed for sleep.
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

Tracked on FU-106; the gap register (IAC-G01..G06, `iac-lane-fsm.yaml` — G07 shipped without
ever entering it) IS the list. The order as EXECUTED: G07 + G02 + G03 (2026-08-02) → G05
rung-0 (sleep-tracking#113) + G04 sentinel v1 shadow (2026-08-03).
**Remaining: the G01 ENFORCEMENT flip after the sentinel shadow soak (plan in §L0b), then the
G06 advisory lens; window rungs 1/2 when oracle's gateway metering (T3c) exists.**
**Historical reprioritization note (2026-08-02, commit-history audit):** G07 pin-follow was the
biggest *mechanical* win (no LLM, deterministic, the most frequent human commit in oracle-iac)
and can ship independently of the order above; and once oracle-iac gains a fixer block (the
FU-106 twin, operator-wanted), G04 rises with it — fixer volume without the sentinel widens the
G01 hole.
