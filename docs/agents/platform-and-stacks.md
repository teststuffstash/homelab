# Platform ⟷ stack separation — the agents framework as a platform capability

**This doc owns the platform ⟷ stack boundary** — the composition axes, what a stack may declare
versus what the platform renders, service discovery, and the credential-airlock pattern. It records
the direction; the code that exists is deliberately shaped so the migration stays a *lift, not a
rewrite*. Open legs are FU-049 (XRD-generated catalog) and the FU-039 self-service program
(`ROADMAP.md` → Programs in flight).

## The theory

homelab is a **platform**, not the owner of every stack's configuration. Like a cloud provider, it should
**publish its capabilities as an API and let stacks self-serve** — the same lens as boot-from-git and the
per-stack `-iac` model (FU-025, ADR-084). Two moves fall out:

1. **The agents framework becomes a platform capability, published as a Crossplane XRD.** homelab owns the
   *mechanism* (how a scoped coordinator/reviewer/worker pod is spawned, the deterministic gate + reflex
   loop, RBAC, secret wiring). Each stack owns its *policy* (which repos, which model tiers, which tools,
   its git workflow, its review rubric). A stack declares `kind: AgentStack` in its own `-iac` repo;
   homelab's Composition renders the control plane for it. **Mechanism = platform; policy = stack.**
   **(2026-07-17, ADR-093:) the orchestration engine underneath is now Argo Workflows + Events — the
   agent-loop reflexes run as Argo CronWorkflows, and the review path is event-driven (github-exporter
   POSTs reviewable PRs → Argo Events Sensor → review WorkflowTemplate → reviewer, */15 CronWorkflow
   backstop). Argo Workflows is itself a claimable capability — a textbook mechanism/policy split: a
   stack sets `argo.enabled: true` on its AgentStack claim and the platform renders a workflow SA +
   workflowtaskresults RBAC into its namespace, while the stack authors its own WorkflowTemplates /
   CronWorkflows (DAG + step images = stack policy; Garage is the S3 artifact repo). First consumer:
   oracle-fleet ingestion.)**

2. **Platform services are published as XRDs too — superseding `SERVICES.md` as the source of truth.**
   Today apps discover services by grepping a hand-maintained markdown catalog. The target: the platform's
   provisionable capabilities are typed Crossplane XRDs (S3 bucket, Postgres, …); discovery is a cluster
   query (`kubectl get xrd` / `kubectl explain`), and the human-readable catalog is *generated* from the
   XRDs rather than curated by hand. The XRD is catalog + schema + provisioning API in one.

## Composition axes (operator direction 2026-07-25)

A ride is a point in a **four-axis space**, and the axes must stay orthogonal — any combination
must be launchable ("an opencode ride, idp stack, coordinator role, kimi model"):

| axis | values today | future | owned by |
|---|---|---|---|
| **harness** | goose, opencode (agent-base) · claude (coordinator image) | hermes, … | agent-runtime (one image per harness family, **stack-agnostic**) |
| **role** | fixer, coordinator, reviewer(+lenses), retro, scout, responder, researcher, infra-fixer | prober, meta-coordinator, large-job | **[`roles.md`](roles.md)** — recipes/briefs + the role's ns/credential boundary + its **activation machinery** (see the boundaries bullet below) |
| **stack** | sleep, oracle, platform, circles | … | AgentStack claim (ns, keys, repos) + the stack repo itself |
| **model / billing** | Claude subscription · OpenRouter API (registry + chains) | opencode subscription, … | model-routing registry + the ADR-081 proxy |

Known constraint couplings (encode them, don't fight them):

- **Models are harness-free under API billing — it's the SUBSCRIPTION billing path that binds**
  (operator correction 2026-07-25): claude-family models on goose via OpenRouter is a real
  cell; only the Claude *subscription* is reachable solely through the claude CLI + OAuth
  token (a future opencode subscription likewise, with its own hard limits). Harness↔model
  *affinity* ("some harnesses work better with some models") is empirical, not structural —
  FU-095(b) is the evidence instrument, the ledger axes the metric.
- **Roles carry boundaries AND activation machinery, not images**: retro rides must not hold
  the fixer WIP slot (FU-058 P3), the coordinator's toolchain is fixed (§below), the reviewer
  needs full-repo read. Role = recipe + RBAC/ns + **the machinery that decides when and how it
  fires**: the dispatch predicate, the edge trigger (emitter arm → Sensor dep → submit
  Workflow), the level-triggered backstop cron, idempotency/serialization keys, capacity
  gates, and breaker hooks. Never a baked image variant. The reviewer's machinery is
  inventoried guard-by-guard in [`merge-path-fsm.md`](merge-path-fsm.md) (MP-T03/T04/T08);
  the coordinator's is the doorbell + scan clauses (ADR-094); retro/scout live
  in `retro-argo.yaml`/`reflexes-argo.yaml`. Two consequences (operator observation
  2026-07-27): standing up a NEW role is mostly machinery design, not prompt work — count the
  reviewer: one rubric vs ~ten machinery pieces; and rendering a role per-stack means the
  AgentStack Composition renders the whole machinery set, not just SA + secrets (FU-080's
  coordinate leg = cron + doorbell RBAC + mutex + broker role; FU-100's review leg = exporter
  arm + Sensor dep + routing trigger — both change zero prompts, zero images).
- **The stack's toolchain cache belongs to the STACK, not the harness image** (FU-096): baking
  repo closures into agent-base would couple harness×stack. Built 2026-07-27: the stack repo's
  CI publishes its devbox closure + eval cache as an OCI artifact versioned with `devbox.lock`
  (thin caller → homelab `devbox-cache.reusable.yml`, level-triggered on lock pushes), and the
  launcher mounts it via ImageVolume (verified on this cluster, fleet#106) read-only at
  `/stack-cache`; the agent-base entrypoint seeds `~/.cache` (exact-lock guard, loud degrade)
  and adds the `file://` store as a substituter. Harness images stay stack-blind; caches ride
  the stack. Rollout state + numbers: FU-096.
- **App charts are TARGET-agnostic; platform fulfillment rides the -iac wrapper** (operator
  2026-07-27, the same coupling rule's third instance): an app chart carries only its
  consumption *contract* (`values.schema.json`, `existingSecret`, endpoint values, default-off
  flags for ecosystem-standard CRDs) and provisions nothing — it must deploy anywhere,
  including outside homelab. Platform-specific provisioning (Crossplane claims, ExternalSecrets)
  lives in the per-target **wrapper chart** in the stack's `-iac` repo, atomic with the chart
  pin (one -iac commit = pin bump + fulfillment = one sync — the meta-11 paired-rolls rule by
  construction). See FU-106 (infra-fixer role, `roles.md`).

The launcher (dispatch params are launcher-owned — ADR-094) is where an axis combination is
assembled into a pod. FU-095(b) supplies the multi-harness evidence; ADR-077's meta-harness
trigger fires only if governing multiple harnesses becomes real.

## Ownership, target state

```
homelab (platform)                         <stack>-iac (e.g. sleep-iac)          the platform surface
──────────────────                         ────────────────────────────         ───────────────────
publishes:                                 declares (its POLICY):               consumes via the k8s API
  • AgentStack XRD + Composition             kind: AgentStack                    kubectl get agentstacks
    → coordinator gate/CronWorkflow            spec: repos, modelTiers,          kubectl get xrd
    → review Sensor+Wf                               tools, gitWorkflow,          (no more grep SERVICES.md)
    → RBAC + ESO secret wiring                       reviewRubric
  • service XRDs (S3/Postgres/…)            kind: Bucket / PostgresInstance
    → supersede SERVICES.md                  (already app-owned, ADR-076)
```

The agents *framework code* (`agents/coordinator-session.sh`, `reviewer-session.sh`, `review-reflex.sh`,
the briefs) is then packaged by the platform for consumption — a stack pins a version and gets the control
plane, without copying scripts into its repo. What the stack writes is the **claim**, not the machinery.

## First cut (today, homelab-side)

Pragmatic stand-ins that already run, structured to become the above:

- **`agents/stacks.json`** — a claim-shaped list of stacks
  (`{name, repos, mainRepo, coordinatorModel, workerModel}`). The claims EXIST now (step 3
  below, done 2026-07-12) — this file survives as their **committed mirror** (the CI/registration
  lint's universe + the probe-failed belt; [`agentstack.md`](agentstack.md) §Consumption).
  `mainRepo` (see below) is stack policy: the coordinator's cwd.
- **`agents/coordinator-scan.sh`** (`devbox run coordinator-scan`) — the **deterministic gate** in front of
  the LLM coordinator: per stack, list open issues/PRs and answer "is there anything a coordinator tick
  would act on?" (predicate in the script header, mirrors `coordinator/README.md` §State machine). Reports
  the actionable items + the scoped launch command; `--spawn` launches a headless tick. **No subscription
  tokens are spent to discover "nothing to do"** — the cheap sibling of `review-reflex.sh`.
- **`coordinator-session.sh --stack/--repos/--main-repo`** — scope a session to a stack (prepends the stack
  context to the tick prompt, sets `STACK`/`AGENT_REPOS`/`MAIN_REPO` pod env). It **clones every `--repos`
  entry** shallow into `/work/<repo>` (private oracle-* repos via the pod's `GH_TOKEN`, `gh repo clone`;
  a failed optional clone is loud-but-non-fatal) and **cd's into `--main-repo`** before launching Claude.
  `--tick`/`--run-tick` share one `TICK_PROMPT` so an interactive first run == the future reflex's call.
  - **`mainRepo` (stack policy).** A stack's **main repo** is the coordinator's cwd — the repo whose
    `CLAUDE.md` + specs should load as the session's natural context. It is the stack's *home of coordination
    knowledge*: `oracle-fleet` for the oracle stack (its `specs/TRACKS.md` = the lane/WIP rules the
    coordinator sequences by), and `homelab` for stacks whose coordination knowledge still lives in homelab
    docs (`sleep`, `platform`) until it migrates out. It is distinct from the platform *mechanism*: the
    coordinator **brief** (`agents/coordinator/README.md`) is always loaded by absolute path from
    `/work/homelab`, whatever the cwd. `mainRepo` is a field of the future `AgentStack` claim, defaulting to
    `homelab`. All the stack's repos are cloned regardless of which is `mainRepo`; the clones are **read-only
    reference** (coordinator writes stay labels/comments/merge via `gh`; a direct-write tier is FU-059).
- **`agents/fixer/<repo>/` + the `agent-fixer` ApplicationSet** — the per-repo *fixer infra* (the
  project's `OpenRouterKey` budget key + the `agent-git-token` ESO `GithubAccessToken`, namespace ==
  repo). One `argocd/platform/agent-fixer.yaml` ApplicationSet (git **directory generator** over
  `agents/fixer/*`) emits an Application per subdir, so **onboarding a repo's fixer infra is just adding
  its `agents/fixer/<repo>/` dir** — no per-repo Application file, no shell (the "yaml way", FU-052). The
  per-repo `.agents/fix.yaml`+`review.md` recipes and the GitHub-side (repo/labels/rulesets/callers, still
  `tofu/github` + reusable workflows) are the parts *not* yet folded in; the `AgentStack` XRD (FU-048)
  collapses both into one claim.
- **Orphan backstop** in `coordinator-scan` — reports any open `dependencies` PR that is un-armed AND
  carries no lane label (`automerge`/`deps-review`/`major`), i.e. owned by nobody (Renovate is meant to
  classify+arm every bump; escapes rot silently otherwise — a disabled manager's leftovers, stale PRs, a
  human's dep PR). Report-only. Caught sleep-tracking#14/#15 live.

## Coordinator toolchain — fixed, NOT per-stack

A recurring question as coordination goes per-stack: *which devbox does the stack coordinator use?* **None
— it's an orchestrator, not a builder.** Its toolchain (`gh`/`kubectl`/`git`/`python3`/`jq`/`claude`) is
**stack-independent** and baked into the `agent-coordinator` image (a plain Dockerfile — no runtime
devbox). It never builds or tests; per-repo build toolchains live in the **worker** pods, which clone the
project repo and materialize *its* `devbox.json` at runtime. So making the coordinator per-stack changes
*which repos it watches* (gh scope) + its context — **not** its toolchain. This is the ADR-085 line again:
coordinator toolchain = platform **mechanism** (in the image); per-repo build toolchain = stack **policy**
(the repo's `devbox.json`, consumed by workers). If the coordinator ever needs to *read* a stack's `-iac`
YAML it's `git` + maybe `yq` — still fixed and stack-independent; genuinely stack-specific coordinator
tooling would be a per-stack image variant selected by the future `AgentStack` Composition.

**The one swap-point:** `coordinator-scan.sh`'s `stacks_json()` reads `stacks.json` today; the target
is `kubectl get agentstacks -o json`. Everything downstream (the per-stack loop, the gate, the spawn) is
already source-agnostic, so flipping the source is the migration.

## Why per-stack is the coordinator's context (not per-issue, not global)

The coordinator is a level-triggered reconciler whose value is *cross-repo sequencing* (an app PR that
triggers an `-iac` bump; land provider before consumer; a `major` bump spanning repos). Per-issue loses
that and multiplies LLM sessions; global couples unrelated stacks and bloats context. A **stack** — its
`-iac` repo + app repos — is the coherent unit of ownership, budget, platform-facts, and the deploy chain.

## Migration path

1. **Now:** `stacks.json` + `coordinator-scan` (report) + `--stack` scoping. Supervised interactive ticks.
   **✅ DONE ~2026-07-17 (superseded by the item-scoped scan).**
2. **coordinator-reflex** — an Argo **CronWorkflow** (ADR-093; was a k8s CronJob) running
   `coordinator-scan --spawn` per schedule (FU-050); the gate keeps the LLM off empty wakes. The
   review path is event-driven (machinery home: [`roles.md`](roles.md) §reviewer +
   [`merge-path-fsm.md`](merge-path-fsm.md)). Graduating to autonomy is a scheduler swap, not a
   behavior change. **✅ DONE 2026-07-21 — per-stack `coordinate-<stack>` loops.**
3. **Publish the `AgentStack` XRD + Composition** in homelab; move one stack to a claim in its `-iac`;
   `stacks_json()` → `kubectl get agentstacks` (FU-048). **✅ DONE 2026-07-12 — first claim = oracle
   (not sleep: oracle's `-iac` agent dir was already GitOps-owned). See
   [`agentstack.md`](agentstack.md); `stacks_json()` now merges cluster claims over stacks.json.**
4. **Service XRDs** become the discovery source of truth; generate a catalog, retire/auto-generate
   `SERVICES.md` (FU-049).

## Open questions — all three since resolved (2026-07-12, with the FU-048 build)

- **Build-time discovery.** ✅ Resolved: **keep `agents/stacks.json` as the committed MIRROR of the
  claims** — the registration lint's repo universe in CI (no cluster creds) and the probe-failed
  fallback belt both need it. Generating it *from* the claims is FU-049's catalog problem. See
  [`agentstack.md`](agentstack.md) §Consumption.
- **How much policy is a claim vs a Composition default?** ✅ Drawn in the built XRD: baseline +
  ecosystem `profile` + `extraFQDNs` for egress, `fixer` block per repo (docker, storage), platform
  defaults for the rest ([`agentstack.md`](agentstack.md) §What a claim renders).
- **One coordinator per stack vs one that iterates stacks.** ✅ Decided 2026-07-17: one global
  reflex with per-stack claim knobs (`spec.coordinator.enabled` / `spec.reviewer.enabled`).
  **Superseded 2026-07-18 (FU-080 per-stack build):** the Composition now renders a
  `coordinate-<stack>` CronWorkflow into `<stack>-agents` (claim `loop.perStack`), running as the
  namespaced `agentstack-loop` SA with broker-fetched, stack-scoped git tokens (TokenReview'd
  `/loop-git-token`); oracle graduated 2026-07-18 and runs per-stack since. **COMPLETE 2026-07-27 (circles joined 2026-08-03 — four):
  all stacks graduated (coordinate + review loops in-ns, 2026-07-26); the global surface is the
  ADR-120 **[switchboard](workflow.md)** since 2026-08-31 (Sensor-edge resolver — repo-dumb rings + capacity
  fan-out; the coordinator-reflex cron retired, per-stack crons are the failure detector); the per-stack review EDGE shipped as FU-100 (2026-07-27).** model-scout +
  ledger stay global. [`agentstack.md`](agentstack.md) §Decisions.

## Stack economics — scaling the merge path (moved from merge-path.md, 2026-07-27 / FU-107)

**Per-repo invariant:** per merged PR in steady state, `CI cycles = 1 initial + 1 update`
(update skipped when master hasn't moved) and `reviewer runs = 1`, plus one extra of each per
master-interruption in an approval→merge window. A batch of N concurrent PRs in one repo costs
~2N−1 CI / N reviews (the serializer); across repos everything composes linearly (own master,
own updater chain, own review queue).

**Platform extrapolation** (reference stack ≈ IDP: TARA-Login fork, identity-store, passkey,
`idp-iac` → ~4–5 repos, service repos on the ~20-min ADR-082 full-stack gate; sizing target =
sleep + IDP + one more ≈ 12–15 agent repos, ~50 merges/~54 reviews/~100 CI cycles per week).
What saturates first:

- **Reviewer throughput (the binding constraint):** ~4–7h reviewer wall/week on ONE operator
  subscription shared with the coordinator. The failure mode is the BURST (Renovate Monday ≈
  21 reviews); levers in order: Renovate grouping + per-stack schedule staggering (Mon=sleep,
  Tue=IDP, …), CI-only merges per dep class (FU-046 split — shipped), a second subscription for
  overflow (decorrelation doctrine: reviewer model ≥ author model — a cheap-model reviewer is
  NOT acceptable overflow). Reviews are already at the theoretical floor (1/PR); past it only
  policy and scheduling help.
- **ARC runner pool:** ~25h runner wall/week, capacity fine; the compounding cost is
  single-repo DRAIN LATENCY on full-stack-gate repos (~25–30 min/merge serialized) — FU-015
  (shipped) halves the constant; keep batches small.
- **Updater/API:** free at any plausible scale (in-cluster since ADR-111 — exporter edge +
  one `*/15` Argo cron over the whole repo universe; the hosted reusable + callers retired
  2026-08-26).

**What breaks first:** reviewer quota on burst days (stagger Renovate; dep-bump policy decided
— FU-046) → single-repo drain latency → nothing in the merge mechanics itself (per-repo chains
independent; onboarding a repo = a workflow caller + a `protected_repos` entry).

**Out of scope:** cross-repo coordinated changes — ordering across repos is the coordinator's
job (provider before consumer), now typed by the FU-106 contract/fulfillment split above.

## Cross-stack demand & escalation (ADR-119, 2026-08-30)

Goals are stack-scoped (ADR-106) and code write never crosses stacks — so cross-stack need has
exactly two typed channels, replacing operator memory and gitignored upload files:

**The capability-request lane (demand up, approval down).** A stack files an issue in its OWN
repo (its `-iac` for infra-shaped needs), labeled `platform-request`, carrying a
machine-readable fingerprint line (the `Touches:`/`Budget:` body-line grammar):

```
Capability: public-edge.abuse-fairness
```

- **The fingerprint names an INTENT on a surface, never a mechanism.** A normal consumer can
  say "public, secure, fair to anonymous clients" — it cannot name WAF rules or RUM, and a
  grammar that requires the mechanism name systematically misses real demand (the WAF case,
  operator 2026-08-30). When the requester happens to know the mechanism, it goes in the body
  as a hint; the fingerprint stays at intent altitude — which is also what lets demand POOL:
  two stacks wanting one outcome through different imagined mechanisms count as 2, not 1+1.
- **Surface**: a homelab board slice groups open `platform-request` issues across stack repos
  by fingerprint with a stack count — the ≥2-stacks generalization bar as a number.
- **Approval is PULL-only** (the ADR-102 cross-goal doctrine one ring out): the request
  transfers nothing. The platform cites the charter line making it in-scope, files its side
  into the work map or an open platform Goal, wires the cross-repo `blockedBy` edge, and
  leaves a **disposition comment** — rejection ("not a platform knob — solve stack-side") is
  a disposition too, so requests never rot. The requester's issue closes on CONSUMPTION,
  never on the platform merge (done-means-deployed, both sides).
- **Secure-by-default bounds the lane's vocabulary**: a capability whose honest consumer
  answer is always "yes" ships as the DEFAULT bundle of its capability profile (e.g. a
  public-exposure `api` profile carries rate limits/origin policy unasked; a `consumer`
  profile carries caching/RUM), tunable via claim fields — stacks request TUNING or genuinely
  stack-specific needs, never existence. The egress dial's baseline tier is the precedent.

**The escalation terminal (cross-boundary faults, machine-authored).** When a stack-lane
judgment session (arbitrate, ci-red ruling, triage) diagnoses a cause OUTSIDE the stack's own
repos — platform credentials/tokens, platform-rendered config, cluster infra leaking into
stack CI — it FILES direct on homelab per the coordinator brief's filing contract
(dedup-first, inert, evidence grammar, rate-bounded) and wires a native `blockedBy` edge from
the stuck stack issue to the filed one. Two asymmetries are load-bearing:

- **The stack names the boundary crossing; the platform names the lane.** Component
  attribution (agent-runtime vs coordinator vs a mint manifest — or mechanical-OOM vs
  agents-machinery) is platform context; the stack terminal does not guess. homelab is the
  one filing target; the platform's own intake (board classes, the responder's
  platform-machinery gate, ADR-110's small/big sort) routes onward.
- **Un-park is machinery, not memory**: the `blockedBy` edge holds the stack issue under the
  existing FU-087 dependency gate; the platform fix closing its issue releases the stack
  issue on the next scan pass. (PR-shaped blocks — a review mid-flight — still need their own
  re-entry edge; the open residue.)

**Honest limit** (recorded so nobody mistakes the lane for complete demand coverage): a
consumer also cannot name intents for problems it does not know it has. That residue is
carried by the profile defaults above and by the FU-049 catalog making the *askable* surface
discoverable — the lane carries the rest.

## The credential-airlock pattern (stack jails, FU-080)

A stack's agent loop is driven from a **per-stack jail** on the operator's machine
(`claude-jail tools/stack-jail.sh`), NOT with cluster-admin. The airlock: the HOST holds the admin
kubeconfig and mints a **short-lived, namespace-scoped derivative** token, injecting only that into
the jail — the admin credential never crosses the boundary. Concretely for oracle:
`kubectl -n oracle-fleet create token oracle-workbench --duration=72h` (host, admin) → the jail gets
a 72h token for the `oracle-workbench` SA, which is **namespace-admin in the one fixer namespace and
nothing cluster-scoped** (`oracle-iac//oracle-fleet/agent/workbench.yaml`). Blast radius is that
namespace's own worker creds (branch-only git token, budget-capped OpenRouter key) — accepted.

Two aggregation gaps bite this pattern, because the `admin` ClusterRole only aggregates API groups
carrying the aggregation label and the platform CRDs don't: the jail needs **explicit namespaced
Roles** for `tf.upbound.io` workspaces (observe infra provisioning) and `openrouter.teststuff.net`
openrouterkeys (drive the session-key mint→observe→delete its loop needs) — both hand-added to
`workbench.yaml` (FU-080 b).

**Endgame (FU-080) — REACHED 2026-07-27, all legs:** the Composition renders the per-stack
`agentstack-loop` SA + namespaced launch Role (pods/exec/pvc/openrouterkeys) AND the
`coordinate-<stack>` + `review-<stack>` CronWorkflows in `<stack>-agents` (claim
`loop.perStack`/`loop.graduated`) — the per-stack loops run there as that SA holding only `ref:`
creds + broker-fetched stack-scoped git tokens, so the namespace-admin workbench controls the
loop by construction, zero cluster-scoped grant, zero cross-namespace reach. Oracle graduated
2026-07-18; sleep + platform 2026-07-26; the global belts skip graduated stacks; the per-stack
review edge (FU-100) closed the last latency gap 2026-07-27.
