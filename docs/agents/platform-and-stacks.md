# Platform ⟷ stack separation — the agents framework as a platform capability

**Status: direction set (2026-07-05), first cut built + RAN LIVE in homelab.** Tracked as
FU-045/FU-048/FU-049/FU-050. This doc records where the agents framework and service discovery are heading;
the code that exists today is the pragmatic first cut, deliberately shaped so the migration is a *lift, not
a rewrite*. First live proof (2026-07-05): `coordinator-scan` flagged sleep-tracking#18, and a scoped
**opus** coordinator drove the major-devbox lane (FU-047) end-to-end to a human merge.

## The theory

homelab is a **platform**, not the owner of every stack's configuration. Like a cloud provider, it should
**publish its capabilities as an API and let stacks self-serve** — the same lens as boot-from-git and the
per-stack `-iac` model (FU-025, ADR-084). Two moves fall out:

1. **The agents framework becomes a platform capability, published as a Crossplane XRD.** homelab owns the
   *mechanism* (how a scoped coordinator/reviewer/worker pod is spawned, the deterministic gate + reflex
   loop, RBAC, secret wiring). Each stack owns its *policy* (which repos, which model tiers, which tools,
   its git workflow, its review rubric). A stack declares `kind: AgentStack` in its own `-iac` repo;
   homelab's Composition renders the control plane for it. **Mechanism = platform; policy = stack.**

2. **Platform services are published as XRDs too — superseding `SERVICES.md` as the source of truth.**
   Today apps discover services by grepping a hand-maintained markdown catalog. The target: the platform's
   provisionable capabilities are typed Crossplane XRDs (S3 bucket, Postgres, …); discovery is a cluster
   query (`kubectl get xrd` / `kubectl explain`), and the human-readable catalog is *generated* from the
   XRDs rather than curated by hand. The XRD is catalog + schema + provisioning API in one.

## Ownership, target state

```
homelab (platform)                         <stack>-iac (e.g. sleep-iac)          the platform surface
──────────────────                         ────────────────────────────         ───────────────────
publishes:                                 declares (its POLICY):               consumes via the k8s API
  • AgentStack XRD + Composition             kind: AgentStack                    kubectl get agentstacks
    → coordinator gate/CronJob                 spec: repos, modelTiers,          kubectl get xrd
    → review-reflex                                  tools, gitWorkflow,          (no more grep SERVICES.md)
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
  (`{name, repos, mainRepo, coordinatorModel, workerModel}`). This is the temporary home of what will become
  one `AgentStack` claim per stack, living in each `-iac` repo. Header comment says so. `mainRepo` (see below)
  is stack policy: the coordinator's cwd.
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

**The one swap-point:** `coordinator-scan.sh`'s `stacks_json()` reads `stacks.json` today; the FU-045 target
is `kubectl get agentstacks -o json`. Everything downstream (the per-stack loop, the gate, the spawn) is
already source-agnostic, so flipping the source is the migration.

## Why per-stack is the coordinator's context (not per-issue, not global)

The coordinator is a level-triggered reconciler whose value is *cross-repo sequencing* (an app PR that
triggers an `-iac` bump; land provider before consumer; a `major` bump spanning repos). Per-issue loses
that and multiplies LLM sessions; global couples unrelated stacks and bloats context. A **stack** — its
`-iac` repo + app repos — is the coherent unit of ownership, budget, platform-facts, and the deploy chain.

## Migration path

1. **Now:** `stacks.json` + `coordinator-scan` (report) + `--stack` scoping. Supervised interactive ticks.
2. **coordinator-reflex** CronJob running `coordinator-scan --spawn` per schedule (FU-050) — the gate keeps
   the LLM off empty wakes. Graduating to autonomy is a scheduler swap, not a behavior change.
3. **Publish the `AgentStack` XRD + Composition** in homelab; move one stack to a claim in its `-iac`;
   `stacks_json()` → `kubectl get agentstacks` (FU-048). **✅ DONE 2026-07-12 — first claim = oracle
   (not sleep: oracle's `-iac` agent dir was already GitOps-owned). See
   [`agentstack.md`](agentstack.md); `stacks_json()` now merges cluster claims over stacks.json.**
4. **Service XRDs** become the discovery source of truth; generate a catalog, retire/auto-generate
   `SERVICES.md` (FU-049).

## Open questions

- **Build-time discovery.** XRD discovery is a cluster query; an app repo's CI may have no cluster creds at
  build time. Provisioning-discovery (in `-iac`, which reconciles against the cluster) fits XRDs cleanly;
  documentation-discovery for a human/CI without cluster access may still want a generated static catalog.
- **How much policy is a claim vs a Composition default?** Model tiers, budget caps, git-workflow and the
  review rubric are stack policy — but sensible platform defaults keep a minimal claim minimal. Draw the
  line when writing the XRD (FU-048).
- **One coordinator per stack vs one that iterates stacks.** The gate already iterates; whether each stack
  gets its own long-lived control plane or shares one is a Composition decision (FU-048).
