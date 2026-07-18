# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-091**.
- **This file is the only tracker.** Everywhere else — docs, code comments, commit messages —
  reference the id (e.g. `FU-007`), never a free-floating `TODO`. Detailed context may stay near
  the code/doc it concerns; the item here carries the one-liner and links to the detail.
- **Don't file what's faster to do:** if it takes ≲5 minutes, the context is already in hand, and
  it's safe to do now — just do it. An entry costs more than the fix; file only genuine deferrals.
- **Resolving an item:** move it to [`follow-ups-archive.md`](follow-ups-archive.md) in the same
  commit as the fix, trimmed to the grep residue (what shipped / when / acceptance evidence /
  gotcha — a few lines) with an *(archived YYYY-MM-DD)* stamp. References elsewhere stay legal
  while the id is archived; when the entry expires out of the archive (≈a month, once stable),
  delete it and scrub remaining references in living code/docs — TICK-LOG/ADR references are
  historical and exempt. `devbox run follow-ups-lint` checks all of this.
- **Adding an item:** next free id, into the fitting theme section (ids don't encode theme), bump
  the counter above.
- **Single-writer contract (2026-07-10):** this file is operator/meta-edited ONLY — agents never
  append here. The sequential ids + the counter line make it a guaranteed merge conflict under
  parallel writers, and it doesn't scale past platform loose-ends anyway. Agent-discovered
  shortfalls go to the governing repo's `specs/` as id-free `⚑ gap` flags (ADR-086, oracle-fleet
  ADR-OF-003); coordinator session findings go to the TICK-LOG.

_Last updated: 2026-07-16._

## Secrets (the "secret cleanup" track)

- [ ] **FU-005** — Decide whether an Infisical break-glass second admin is worth codifying (one
      super admin today, signups disabled).

## GitOps & platform

- [ ] **FU-073** — **Pull-through OCI registry mirrors — CORE LIVE 2026-07-14 (ADR-091):**
      `registry-cache` ns, registry:3 pair (docker.io + ghcr), longhorn-bulk cache PVCs, BGP
      VIPs `.40.20/.21`; docker-mode agent rides wired (dind `registry-mirrors` + the
      `REGISTRY_MIRROR_*` env contract) and the docker.io FQDNs dropped from the agentstack
      egress (E2E under enforced deny-all: alpine 2s cold / 1s warm from a kata ride).
      **Remaining consumers:** (a) ✅ DONE 2026-07-16 — `machine.registries.mirrors` on all 8
      nodes (`local.registry_mirrors_patch`, talos.tf + metal.tf; skipFallback default=false so
      a dead mirror/cold boot falls through to upstream). Restart semantics ANSWERED: applies
      in-place, no reboot (canary wk-01 stayed Ready; pull of uncached alpine:3.18.12 rode the
      mirror — containerd/v2.2.3 `?ns=docker.io` in the mirror log, cache-filled + served);
      (b) ci-runner-01 `daemon.json`;
      (c) ARC runner pods; (d) ✅ DONE 2026-07-16 — oracle-fleet#35: `e2e-kind.sh` writes a
      `certs.d/hosts.toml` per registry into the kind node when the ride exports
      `REGISTRY_MIRROR_*` (kindest/node ≥ kind 0.27 preconfigures containerd's `config_path`;
      no-op on the CI VM). Acceptance = the FU-081 r4 green in-pod gate (garage image pulled
      through the mirror under the enforced CNP); (e) ✅ DONE
      2026-07-16 — `nixcache` LB VIP `192.168.40.23` (+ CNP belt in the agentstack Composition);
      the launcher passes `NIX_CACHE_URL=<VIP>` on docker rides (the agent-base entrypoint
      already honored the env — no agent-runtime change needed). Verify on the next kata ride:
      `devbox install` should be LAN-speed, not the ~4-min WAN fallback observed 2026-07-14.
- [ ] **FU-076** — **Re-check the metal reinstall mystery on the next metal (re)install**: a
      maintenance-mode reinstall of wk-metal-03 applied config verifiably carrying the
      metal_kata installer URL yet produced the plain-metal schematic (fixed via `talosctl
      upgrade`; likely also the origin of the kata `/dev/kmsg` regression, see
      `docs/spikes/kata-ci-gate.md`). Verify install.image is honored from maintenance mode.
- [ ] **FU-072** — **Kata guests can't reach cluster-service VIPs** (Cilium 1.19, kubeProxyReplacement,
      `bpf-lb-sock=false`). Diagnosed 2026-07-13 on wk-metal-03: from a kata pod, pod-to-pod
      (incl. cross-node coredns POD IP, UDP+TCP) and external-by-IP all work; ANY 10.96.x service
      VIP (UDP and TCP) black-holes — per-packet service translation isn't happening for
      kata-veth traffic even though it works for runc pods on the same node.
      `socketLB.hostNamespaceOnly=true` applied (tofu/cilium.tf) — no effect (socket LB was
      already off). Next probes: hubble verdicts on the kata endpoint for 10.96/16 traffic,
      cilium-dbg bpf lb list from the node agent, upstream cilium+kata issues. Workaround in
      place: kata CI-gate pods run `dnsPolicy: None` + the LAN resolver (192.168.2.1) — fine for
      k3d/registry work, blocks in-cluster consumers (garage transcripts upload from kata pods).
      2026-07-18 (meta-8): the launcher's endpoint-IP rewrites additionally need endpoints-read
      for IN-CLUSTER dispatchers — granted (agent-coordinator + agentstack-claims-read
      ClusterRoles); before that, coordinator-dispatched kata rides shipped raw svc URLs and the
      claude harness died ConnectionRefused (oracle-fleet#52 r1 strike).

- [ ] **FU-007** — **ArgoCD → Forgejo cutover** (offline-resilience goal). Prereq: pull-mirror the
      **homelab** repo itself into Forgejo (the `sleep-lab` org mirrors exist since 2026-06-21).
      Then flip `var.argocd_repo_url` + child-app `repoURL`s and deliver the Forgejo read cred via
      ESO. Procedure: `argocd/README.md` → "Forgejo cutover".
- [ ] **FU-010** — Infisical↔CNPG uses `sslmode=disable` (node-pg rejects CNPG's self-signed
      cert). Fine pod-to-pod; revisit if Cilium transparent encryption lands.
- [ ] **FU-011** — Pin the Crossplane `provider-terraform` package to a digest (currently the
      `:v1.1.1` tag).
- [ ] **FU-012** — Remote/encrypted tofu state backend (every root is local, gitignored state).
- [ ] **FU-013** — Home Assistant `/config` (and other stateful data) backup → Garage S3 with the
      bucket-id in git — the missing "boot-from-git" DR leg (Longhorn replicates in-cluster, it
      doesn't DR). `tofu/homeassistant.tf`.
- [ ] **FU-039** — **Platform self-service via Crossplane** (the "homelab as AWS/Civo" gap): a
      project can already IaC its S3 buckets/keys (ADR-076 Workspaces), OpenRouter keys
      (`OpenRouterKey` CR) and Postgres (CNPG `Cluster` CR) — but **not** its git repos
      (`tofu/github/`, admin PAT outside the jail), HTTPS names (OPNsense ansible), or its own
      ArgoCD AppProject/namespace. Decide per resource: Crossplane provider vs a thin homelab PR
      seam. Prereq for the FU-025 per-stack IaC-repo model.
      **HTTPS-names leg DELIVERED (ADR-092, 2026-07-15):** per-stack subdomain delegation —
      homelab wires `*.<stack>.teststuff.net` ONCE (wildcard cert + one `3.0/24` VIP + a dumb
      HAProxy TLS terminator → the stack's in-cluster Cilium Gateway; `stack_gateways` in
      `group_vars/opnsense.yml`, opt-in), then the stack adds hostnames as HTTPRoutes in its own
      `-iac` repo, zero homelab change. Opt-in is still a thin homelab PR *once per stack*; making
      that an XRD claim (ADR-085) is the residual. **Still open:** the git-repos + AppProject/namespace
      legs (both still `tofu/github` + `argocd/platform` operator PRs).
- [ ] **FU-055** — Flip the `oracle-fleet` repo `private` → `public` when that stack reaches its
      planned open-sourcing milestone ("P3" in its design doc, kept out-of-repo). The flip is a
      `tofu/github/repos.tf` visibility change + `allow_forking = true` (GitHub forces forking on
      public repos), applied outside the jail. `oracle-iac` stays private permanently.

## CI & dependency automation

- [ ] **FU-051** — **Deploy path per repo so an auto-merged bump reaches prod** (each project owns its
      test+CI+deploy; auto-merging a bump that never deploys is a footgun). BUILT per shape (2026-07-06),
      each via a first-party **deploy-pin PR** — CI-opened, NOT Renovate (Renovate = external deps only) —
      that auto-merges on a CI gate. All use the same readable **`2026.<m>.<d>-g<sha>`** version:
      • **app + chart** → the FU-025 `-iac` bump (sleep-tracking → sleep-iac).
      • **operator / controller** → **Helm chart to ghcr OCI** (ADR-084 shape, NOT the raw-manifest digest-pin
        that was first tried): openrouter-operator packages a chart (version==appVersion==image) to
        `oci://ghcr.io/teststuffstash/charts`; `deploy.yaml` opens a bump PR in **homelab/argocd** (the app
        is multi-source: OCI chart + homelab `$values` for the Infisical store, since the chart is generic).
        homelab `ci` = **`argocd-validate-pins`** proves the pinned chart renders with the values before
        auto-merge. LIVE (`argocd/platform/openrouter-operator.yaml`).
      • **image consumed by pods** (agent-base, agent-coordinator) → pinned by version in
        **`agents/images.env`** (sourced by the session scripts) + `review-reflex.yaml`, off `:latest`
        (no pullAlways, cacheable, traceable); each build's deploy-pin bumps images.env → pods use it on next
        spawn (the review-reflex CronJob rolls via the `agent-coordinator` ArgoCD app). PRs: agent-runtime#5,
        agent-coordinator#4.
      • **snore-recorder** → rides the Renovate flow but its ansible→Pi deploy stays MANUAL (a dep reaches
        the Pi only on the next playbook run; repo split + deploy automation is a separate cleanup task).
      • **homelab** → a CI-gated deploy TARGET (`require_approval=false`, `ci=argocd-validate-pins`).
      Prereqs (done): all agent repos are `github_repository` resources (→ `allow_auto_merge=true`), the
      `homelab-deploy` App installed on homelab, `DEPLOY_APP_*` scoped to the deploy-opening repos.
      **Remaining:** prove a dep bump flows E2E for the operator-chart and pod-image shapes — the
      app+chart shape is proven (sleep-tracking digest bump 2026-07-05 → sleep-iac deploy PR
      auto-merged; caller PRs agent-runtime#5 / agent-coordinator#4 merged 2026-07-06; the Renovate
      rollout itself is archived as FU-014).
- [ ] **FU-052** — **Onboard every APP repo to the agentic loop by DEFAULT** (direction 2026-07-06: the
      full flow — merge-path auto-merge **and** fixer (NL issue → worker → PR → review → merge) — should be
      the default for all app repos, not bespoke per-repo). A repo needs two layers: **(1) merge-path**
      (mostly covered by `new-agent-repo.sh`): managed `github_repository` (allow_auto_merge), agent labels,
      required-checks `ci`, the renovate-approve + update-pr-branch callers, a PR-triggered `ci`.
      **(2) fixer flow** (only sleep-tracking has it today): the `homelab-agents` App installed, an
      `agent-git-token` ExternalSecret, an **OpenRouterKey CR** (per-project budget key → `<project>-openrouter`
      Secret), `.agents/{fix.yaml,review.md}` recipes, a worker namespace, and the repo in
      `agents/stacks.json` (so `coordinator-scan` sees it). **Make it repeatable — DONE for layer-2 k8s
      infra (2026-07-06):** the `agent-fixer` ApplicationSet (git directory generator over
      `agents/fixer/*`, `argocd/platform/agent-fixer.yaml`) auto-emits the per-repo Application, so that
      part of onboarding is just adding `agents/fixer/<repo>/{openrouter-key,git-token}.yaml` —
      **since 2026-07-12 (FU-048): ONE AgentStack claim per stack instead (fixer block per repo);
      see docs/agents/agentstack.md.**
      **Expanded 2026-07-10 (1b4fa54 + agent-fixer fixes):** the *-iac* fixer dirs (`oracle-iac//*/agent`,
      `sleep-iac//*/agent`) are GitOps-owned via per-repo git generators (NB: generator `values` must
      nest INSIDE the git generator block — sibling placement is CRD-pruned; generator-template
      precedence doesn't bind, use uniform spec template + values); registration-lint v2 requires both
      merge-path callers per stack repo (probe-first: repo-visibility check before the callers check,
      -iac deploy targets exempt) — found + fixed snore-recorder's missing renovate-approve caller
      (snore-recorder e8bb33b) on first run. Still per-repo shell/manual: the `.agents/` recipes, the
      `stacks.json` entry, and the GitHub-side
      (`new-agent-repo.sh` merge-path) — the `AgentStack` XRD (FU-048) is the full collapse. The
      `homelab-agents` App is already installed on all four to-onboard repos (matrix in
      `docs/github-apps.md`). **Onboarded so far:** sleep-tracking (reference), openrouter-operator (fixer
      infra + `.agents` PR #5). **Still to onboard:** snore-recorder, agent-runtime, agent-coordinator.
      **EXCLUDED — different workflow (per Rasmus):** sleep-iac (CI-only deploy repo, no
      fixer) and homelab (platform/base-infra, dep policy unresolved). Unattended running still needs the
      per-stack reflex (FU-050). Relates FU-014/FU-045/FU-050.
- [ ] **FU-070** — **`stack-template` org repo — collapse new-stack's step E (main-repo content).**
      The one onboarding step still done by copying oracle-fleet's shapes by hand: CLAUDE.md
      skeleton (read order / gate / invariants / related-repos-as-GitHub-URLs), `.agents/` recipe
      skeletons, devbox `ci`+`scan-secrets`, merge-path caller workflows. Make it a template repo
      (`is_template = true` in repos.tf), instantiate via `gh repo create --template` before
      `new-agent-repo.sh` (which then emits the adopt-import). stack-lint's REPO-03/04/05 already
      verify the result. Relates FU-052.
- [ ] **FU-015** — Custom ARC runner image: bake `xz`/`gh`/devbox + a warm nix store (kills the
      per-job `apt-get` and the ~5 min cold start), and wire the in-cluster nix cache as a
      substituter for runner pods. `docs/ci.md` → "residual costs".
- [ ] **FU-016** — SLSA Phase-1: cosign signing + SBOM + scan on the hosted runners (both tiers).
      Plan: `docs/slsa.md`.
- [ ] **FU-017** — Merge the two runner GitHub Apps (`homelab-arc-…` + `homelab-runner-registrar`)
      — both need only org self-hosted-runners R/W. `docs/github-setup.md` §2.

## Agents

- [ ] **FU-086** — **Item-scoped coordinator dispatch (ADR-094 build): the scan emits work units,
      the session judges one item.** **CORE SHIPPED 2026-07-17, E2E-verified:**
      `coordinator-scan.sh` emits `(clause, repo, item)` units (queued-dispatch | c4c5-redispatch
      | changes-requested | merge-conflict | unarmed-major) and `--spawn` dispatches the single
      highest-priority unit (in-flight before new; WIP=1 kept) via `coordinator-session.sh --item`
      with the stack's `coordinatorModel`; `SCAN_ITEM_MODE=0` = whole-stack rollback (also the
      janitor/manual path). Scheduling predicates in the scan: deps closed (FU-087), lane free
      (`track/*` ≤1 in-progress per lane), repo dispatchable (claim `fixerRepos` — context-only
      repos report as visible ⚠, never dispatch), capacity (subscription-latch pre-spawn).
      Acceptance: a deliberately stale unit (merged PR#53 as changes-requested) re-read live,
      exited clean, fixed only its own item's label drift (#42 → agent/done). STILL OPEN: the
      `arbitrate` clause (rounds-exhausted/flip-flop detection as a unit), the FU-085 compound
      (Sensor submits item units directly; cron sweep emits only missed units), lifting WIP>1
      (lane-parallel dispatch — FU-088 gates are in), janitor-tick cron demotion. Original spec:
      scheduling predicates were: lane free, deps closed (FU-087), repo dispatchable (claim
      fixer block — makes context-only `oracle-iac` a visible predicate), capacity (FU-088 — a
      PREREQUISITE before WIP goes above 1). Keep a ~daily report-only **janitor tick** for
      board-level judgment (direction-change sweeps, orphans, cross-PR smells). Explicitly
      skipped: multi-dispatch TICK_PROMPT (prompt-level parallelism, obsoleted by this). FU-085's
      edge then submits units directly (events are item-shaped); the cron sweep emits missed
      units. Relates FU-050/FU-080/FU-085, ADR-094, oracle-fleet `specs/TRACKS.md`.
- [ ] **FU-080** — **Per-stack coordinator/reviewer rendered from the AgentStack claim → the stack
      jail controls its whole loop.** Decided direction 2026-07-16 (session with the operator; the
      revisit trigger foreseen by agentstack.md §Decisions fired): the oracle stack jail's
      `oracle-workbench` SA (namespace-admin, oracle-iac//oracle-fleet/agent/workbench.yaml) can
      spawn fixer workers but cannot touch coordinator/reviewer (ns `agent-coordinator`) — on
      oracle-fleet#22 the mono jail had to drive the loop. REJECTED: broadening the workbench SA
      into agent-coordinator (pod-create there ⇒ can mount `coordinator-git` — the airlock dies)
      and moving the agents while they held the raw token (retired by FU-066(d), the prereq that
      is now in). The build: the Composition renders per-stack coordinator/reviewer
      identity+launch RBAC (and optionally a per-stack reflex CronJob) INTO the stack's fixer
      namespace — pods there hold only `ref:` creds, so the workbench SA controls the loop by
      construction, zero broadening. Include the two cross-ns leftovers found 2026-07-16:
      (a) ✅ DONE 2026-07-17 (first brick) — `agent-transcripts` ClusterSecretStore (ESO
      kubernetes provider, scoped SA; argocd/resources/agentstack/transcripts-store.yaml) +
      per-fixer-ns ExternalSecret in the Composition; worker pods secretKeyRef the key IN-NS,
      agent-session.sh reads no key material, and the rbac.yaml "one deliberate exception" is
      REMOVED — the coordinator SA now has zero secret access;
      (b) ✅ DONE 2026-07-17 — `oracle-workbench-orkeys` Role+Binding in oracle-iac
      workbench.yaml (openrouterkeys R/W, mint→observe→delete; oracle-iac#34, CI-only merge).
      **Identity+launch-RBAC render DONE + VERIFIED 2026-07-17:** the Composition renders per fixer
      repo a NAMESPACED `agentstack-loop` SA + Role (pods/exec/pvc/openrouterkeys) + Binding — the
      in-namespace equivalent of the global coordinator's cluster-scoped grant, ready for a
      per-stack coordinator/reviewer to run as. Additive (nothing binds a pod to it yet). Verified
      live across all 3 fixer namespaces: loop SA CAN create pods+openrouterkeys in-ns, CANNOT
      create pods cross-ns or read cluster secrets. ⚠ Gotcha (agentstack/rbac.yaml header): k8s
      privilege-escalation prevention blocks Crossplane from COMPOSING a Role that grants verbs it
      doesn't itself hold — the pods/exec/pvc verbs had to be mirrored into the
      crossplane-aggregated ClusterRole (the proxy Role slipped by on core's secrets access).
      Airlock pattern documented in docs/agents/platform-and-stacks.md §"The credential-airlock pattern".
      **`reviewer.enabled` knob CONSUMED 2026-07-17 (first slice):** the global `review-reflex.sh`
      now reads the claims each tick and drops every repo of a stack with `reviewer:
      {enabled: false}` (probe-first: a failed read warns + keeps the full list). Found live: the
      oracle claim's disable had synced but the schema-only knob gated nothing — reviews kept
      firing. The full per-stack CronWorkflow render below stays the real fix.
      **Loop-home brick DONE 2026-07-17:** the Composition renders the per-stack
      `<stack>-agents` Namespace + its `agentstack-loop` SA and adds that SA to every fixer ns's
      loop RoleBinding — cross-ns dispatch on namespaced grants only, verified live (oracle's
      loop SA: pod-create YES in oracle-fleet, NO in sleep-tracking; all three namespaces
      rendered). Cred note: coordinator-claude needs NO per-stack rail — the opaque
      `ref:agent-coordinator/coordinator-claude` resolves at the egress proxy from any ns.
      **PER-STACK LOOP BUILT 2026-07-18 (operator-confirmed decisions):** (1) broker-only creds
      in `<stack>-agents` — the workbench MAY hold pod-create there because no cross-boundary
      Secret exists in the ns (one documented exception: the write-only transcripts S3 key);
      (2) loop git tokens minted CENTRALLY in agent-coordinator (App keys never enter a
      stack-reachable ns), stack-repo-scoped, both Apps (`loop-git-<stack>` coordinator /
      `loop-reviewer-git-<stack>` reviewer — distinct identity, self-approval stays blocked);
      (3) served ONLY by the egress proxy `/loop-git-token` with MANDATORY TokenReview (caller
      must BE `<ns>:agentstack-loop`; the proxy's only cluster-scoped grant; `/git-token` verifies
      an offered SA token, legacy tokenless stays worker-scope-only); (4) Argo Events stay GLOBAL
      (bus+Sensors — dumb pipe; per-stack JetStream = 3×1Gi for ~zero volume); (5) per-stack
      capacity = subscription-latch only (ConfigMap semaphores can't cross ns; DB locks not
      worth it). Render (claim `loop.perStack`, default off): `coordinate-<stack>` CronWorkflow
      in `<stack>-agents` as `agentstack-loop` (broker-fetch preamble, `SCAN_STACK`-scoped scan,
      item dispatch via `coordinator-session.sh --loop-ns`), workflowtaskresults RBAC, transcripts
      PVC+key. E2E 2026-07-18: broker 200-as-loop-SA / 403-foreign-ns / 403-unauthenticated with
      DISTINCT per-App tokens; oracle graduated (`oracle-iac` claim) — see the tick acceptance in
      the session log. **STILL REMAINING:** per-stack REVIEW backstop (reviewer-session.sh needs
      the broker-fetch plumbing its coordinator sibling got; the loop-reviewer token leg is
      already minted+served), retiring a graduated stack from the GLOBAL scan/reflex after soak
      (today both run — the belt), sleep/platform graduation, and the FU-089 fixer-ns key hole
      found during this build. model-scout + ledger stay GLOBAL; docker-ride dispatch from the
      jail additionally waits on FU-072. ADR-094 note: this leg carries NO scheduling semantics.
      Relates FU-045/FU-048/FU-050/FU-066, ADR-093/ADR-094.
- [ ] **FU-090** — **Coordinator-authored issues: harvest + authoring surfaces behind the
      breaker-#1 gate (design 2026-07-18, operator-flagged: "coordinators don't create issues
      themselves yet").** Today issue AUTHORING is a jail-LLM practice (workflow.md §Triggers
      emitter table) and the coordinator files issues only inside meta-4 arbitration — an
      APPROVED PR's `Follow-ups:` section (the rubric REQUIRES issue-ready bullets) has no owner
      and dies in the review comment. Design, two surfaces one gate: (a) **follow-up harvest** —
      the C6/merged item session files each `Follow-ups:` bullet as an issue (provenance links,
      `Depends-on:` lines per FU-087, track label inherited) — BOT-AUTHORED → INERT per TICK-LOG
      §Loop-safety breaker #1 (no agent-fix/agent/queued); (b) **spec-driven authoring** — the
      ADR-094 janitor tick MAY draft issues from specs/TRACKS gaps, same inert gate.
      **Visibility slice SHIPPED 2026-07-18**: the scan reports 🌱 bot-authored issues lacking
      `agent-fix` per repo, so harvested drafts surface for human triage instead of rotting.
      Graduation knob (NOT built): claim `issueAuthoring.selfQueue` (default off) letting the
      coordinator self-label harvested issues, bounded by the existing breakers + a per-day rate
      cap — flipping it is the operator's per-stack trust call (it retires breaker #1 for that
      stack). Relates FU-086/FU-087, ADR-094, TICK-LOG §Loop safety.
- [ ] **FU-089** — **Fixer-ns `agents-github-app` private key = workbench escalation hole.**
      Found 2026-07-18 during the FU-080 loop-token build: the Composition renders the
      homelab-agents App PRIVATE KEY (`agents-github-app` ExternalSecret) into EVERY fixer
      namespace so the per-repo `agent-git-token` generator can run in-ns — but a stack
      workbench SA is namespace-admin there, so it can read the key and mint tokens for ALL
      repos the App covers (cross-stack contents/PR/issues write — exactly the escalation the
      airlock exists to prevent). Fix = the loop-token pattern applied to worker tokens: mint
      per-repo tokens CENTRALLY in agent-coordinator (generators+ES there), serve via the
      proxy's TokenReview-verified `/git-token` (worker pods already fetch per-op — flip them
      to send their SA token and make verification mandatory), delete the per-ns key ES from
      the Composition. Until then the App's blast radius IS the trust boundary between stacks.
      Relates FU-080, FU-020, ADR-087.
- [ ] **FU-019** — Migrate the worker plain `Pod` → agent-sandbox `Sandbox` CR (ADR-078).
      `agents/agent-session.sh`.
- [ ] **FU-067** — **Hubble flow EXPORT → Alloy → Loki (denied-flows event drill-down) — only if
      the drop `destination` label proves insufficient.** Context (2026-07-12): the FU-020 ride's
      ~150 POLICY_DENIED drops were unclassifiable post-hoc (flow ring buffer rotates in minutes);
      fixed at the METRIC level (`drop:…destinationContext=dns|ip` + `dns:query` — Prometheus now
      names denied destinations and attempted lookups, panels on the `agent-issue` dashboard). If
      per-flow detail (pod/port/timing) is ever needed durably: Hubble's built-in
      `hubble.export` (static filter verdict=DROPPED → node file) tailed by the existing Alloy
      DaemonSet into Loki — ALL maintained components. Explicitly REJECTED: the `hubble-otel`
      OTLP adapter (blog-circulated pattern) — the project is archived/unmaintained; Cilium has
      no supported native OTel emitter. Relates FU-020.
- [ ] **FU-058** — **Retro P3: the scheduled retro session** (`docs/agents/observability-and-retro.md`
      §B2). Budget-capped batched LLM retro over the worst-K ledger tasks: transcript slices via the
      MCP tools (not yet built), dated report in `docs/agents/retros/`, process-file PRs only
      (human-gated), scores its predecessor first. The FU-057 ledger it needs is LIVE (archived
      2026-07-16) and accumulating; first run hand-supervised. Absorbs FU-057's small residue:
      ledger-reflex consuming `key_hash` for the OpenRouter activity-API per-request backfill.

- [ ] **FU-059** — **W1 DECIDED + built (2026-07-10, ADR-086): coordinator commits ⚑ spec gap-flags
      to open agent PR branches during merge-forward arbitration (record-in-git; issues = work
      pointers only). Remaining scope = W2+ (direct fixes/seeds), still needs design.** Original:
      **Coordinator write tiers (W1/W2) — needs its own ADR first.** Today the coordinator's
      stack-repo clones (`/work/<repo>`, landed with the FU-045 first brick) are **read-only reference**: its
      only writes are labels/comments/merge-state via `gh`. A future tier could let the coordinator write
      *directly* to a stack repo (open a PR from the clone, push a trivial fix, seed a spec) instead of always
      dispatching a worker — but that blurs the coordinator(orchestrator) vs worker(builder) split and touches
      budget/credential/review-gate assumptions, so it must be designed in an ADR before any code. Relates
      FU-045/FU-048 (the `AgentStack` claim would carry the tier as policy) and the merge-path reflexes.
- [ ] **FU-062** — **Model routing: chains + strikes + a live registry** — the umbrella that binds
      FU-018/FU-021/FU-024/FU-057 into one design (they don't work separately). Full doc:
      [`docs/agents/model-routing.md`](agents/model-routing.md). Core: (1) **rounds ≠ strikes** —
      infra failures (harness-death/auth-storm/timeout) consume NO round; they blacklist the model
      *for that task only* and re-dispatch same-tick on the next `workerModelFallbacks` chain entry
      (`agents/stacks.json`, additive field → the AgentStack "model tiers" slot, FU-048); global
      blacklists come only from the FU-057 model-health ledger. (2) `estimate_budget.py`'s static
      price table → a **live registry** (`/api/v1/models` + `/models/:id/endpoints`; effective price
      = cache-aware per-provider min; interim: the `--price-per-mtok` override recipe now in the
      coordinator brief). (3) **provider pinning per session** (cache lives at the provider —
      FU-018's injection leg). (4) a weekly **model-scout reflex** (new free/cheap tool-capable
      models → canary task → ledger). Routers verified 2026-07-09: `pareto-code`/`fusion` advertise
      no `tools` (park); `openrouter/auto` = paid lottery (last-resort only); `openrouter/free` =
      free router WITH tools (scout candidate). DONE: brief policy block, stacks.json chains,
      tencent/hy3 priced in the estimator; **live registry in `estimate_budget.py` (2026-07-09)** —
      cached /models + per-model /endpoints, cache-aware effective price, `--lookup` provider-pin
      verdict, static table kept as the offline fallback; **strike bookkeeping in the launcher
      (2026-07-09)** — a PR-less run posts `AGENT_STRIKE: model=… error_class=… round=… session=…`
      + the log tail to the ISSUE (the comment is the strike store; brief reads it to walk the
      chain), PR runs get `error_class` in the stats comment; **model-scout reflex v1 (2026-07-09,
      REPORT-ONLY)** — weekly CronJob (`agents/model-scout.sh` + `coordinator/model-scout.yaml`,
      deployed `suspend: true` pending the first supervised run) diffs /models vs the bucket
      snapshot and posts a digest issue; canary dispatch + key minting stay TODO in the script,
      gated on FU-024; **opencode session provider pin (2026-07-09)** — the FU-018 interim leg,
      per-session `OPENCODE_CONFIG` from the registry's `--lookup` pin; **FU-021 investigated** —
      no goose config can stop an auth storm → agent-runtime#8 + `GOOSE_MAX_TURNS=200` interim;
      **goose provider injection LIVE (2026-07-09)** — the ADR-081 v1 egress proxy
      (`argocd/resources/openrouter-proxy/`, E2E-verified: `injected:atlas-cloud`, slug-matched,
      graceful 429 fallback); **FU-021 RESOLVED** (watchdog live-accepted on sleep-tracking#20).
      **Scout first supervised run DONE + UNSUSPENDED 2026-07-16**; **CANARY LEG LIVE 2026-07-17**
      — `agents/model-scout.sh` v2 `canary_one()` mints an ephemeral capped key per candidate
      (only-free guardrail for :free ids), dispatches a trivial closed ride, writes the verdict to
      the ledger + digest, cleans the key. Proven end-to-end: `tencent/hy3:free → clean`. This
      also live-fired **FU-024** (now archived): only-free key + paid model = proxy 403 pre-spend
      (`cost_usd:0.0`, both the router's haiku probe and the target rejected), + free model =
      clean on the same key. **All four legs of the umbrella now live; FU-062 stays open only as
      the routing-doctrine home** — nothing here is unbuilt, close when the doctrine stabilizes or
      fold into model-routing.md. ADR-081 cred-injection (FU-018) + egress lockdown (FU-020) both
      archived 2026-07-17.
- [ ] **FU-044** — **LLM oversight of the deploy path: auto-rollback / roll-forward on a broken
      deploy.** The FU-025 deploy pipeline (app-repo build → chart+image at `<calver>-g<sha>` →
      auto-bump PR in `sleep-iac` → ArgoCD sync, see `docs/sleep-iac.md` §Deploy pipeline) merges on
      CI-green but has **no post-deploy health gate** — a chart that renders + passes kubeconform can
      still break at runtime (bad migration, crashlooping CronJob, failing probe). Add a
      coordinator-style overseer that watches the ArgoCD app health after a deploy PR merges and, on
      a broken sync/degraded health: **roll back** (revert the `sleep-iac` bump PR — deterministic,
      no LLM needed for this half) or, better, **roll forward** — dispatch a worker against the app
      repo to fix the breakage. Prereq the operator is doing first: **harden app CI so prod breakages
      are rare** (the roll-back is the safety net, not the primary control). **Direction: do this
      IN-CLUSTER off ArgoCD app-health events, NOT in the GitHub Actions deploy run** — the deploy job
      now ends at "auto-merge armed" (deploy-pin.sh), so post-deploy health/rollback is decoupled from
      CI (e.g. ArgoCD notifications / a small controller watching `Application` health → revert the
      bump PR or dispatch a fixer). Relates to FU-041 (deterministic merge path) and the agent platform
      direction; the ArgoCD-health signal + that in-cluster reactor are the missing pieces.
- [ ] **FU-049** — **Platform services published as XRDs supersede `SERVICES.md` as the source of truth.**
      Provisionable capabilities (S3/Postgres/…) become typed Crossplane XRDs; discovery is a cluster query
      (`kubectl get xrd`) and the human catalog is *generated* from them rather than hand-curated. Open:
      build-time discovery for an app repo with no cluster creds may still want a generated static catalog.
      Design: [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md) §2, ADR-085. Relates
      [[service-discovery]], ADR-076 (app-owned resources via Crossplane).
- [ ] **FU-050** — **BUILT 2026-07-09 night (98d42f3): CronJob deployed SUSPENDED (unsuspend = the
      autonomy switch, after a clean supervised acceptance round) + scan v2 C4/C5 predicate (verified
      live on oracle-fleet#1's real stall). Red-beyond-T stays open (needs checks:read).**
      **The supervised acceptance round RAN CLEAN 2026-07-12** (manual `coordinator-scan --spawn`,
      one firing): tick arbitrated #8/PR#13 per the meta-4 doctrine (one blocking finding, three
      follow-ups scoped out), dispatched round 2, worker clean, reviewer re-approved — the PR now
      waits only on the CODEOWNERS spec gate (human, by design). The unsuspend precondition is met;
      flipping it is the operator's call:
      `kubectl -n agent-coordinator patch cronjob coordinator-reflex -p '{"spec":{"suspend":false}}'` Original:
      **`coordinator-reflex` CronJob + scan v2.** Run `coordinator-scan --spawn` on a schedule
      (the LLM sibling of `review-reflex`, gated so it never wakes emptily). Plus the v2 predicate that needs
      pod/checks access: `agent/in-progress`+worker-done (round finished / worker failed) and red-beyond-T.
      Relates FU-045/FU-026.
- [ ] **FU-046** — **Agentic dependency upgrades: reviewable dep bumps flow through the merge path, no
      human, no coordinator tick.** Renovate's reviewable bumps (major versions, runtime deps) should NOT
      be assigned to a human; they **arm auto-merge** and get a `deps-review` label, so the existing
      **merge-path review reflex** (`docs/agents/merge-path.md` §Scenario S — a deterministic CronJob,
      NOT a coordinator LLM tick) picks them up like any agent PR and dispatches the **LLM reviewer**.
      The reviewer's verdict drives everything (context = Renovate's embedded changelog/release-notes):
      **harmless → APPROVE → auto-merge** (major upgrade lands, no human); **needs adaptation →
      CHANGES_REQUESTED**, which is the merge path's `changes-requested → round N+1` transition — it
      spawns a **worker to adapt the code on the same renovate branch** → loop → merge. The **coordinator
      only tie-breaks** exceptions (flip-flop / rounds exhausted), per the escalation table. This
      **resolves the merge-path open question** ("review dep PRs or CI-only?") as a *split*: trivial/digest
      → mechanical CI-only approval (the `renovate-approve` reflex, FU-014); reviewable → LLM reviewer.
      **Integration work:** (1) ✅ **DONE** — the review reflex (`agents/review-reflex.sh`) now skips
      `automerge`-labelled PRs (the mechanical path) and reviews the rest, so `deps-review` bumps get the
      LLM reviewer while digest noise doesn't burn a reviewer run; (2) the changes-requested worker must
      fix on a `renovate/*` branch, and **Renovate must not clobber its commits** — set `rebaseWhen:
      conflicted` (done) so the updater owns freshness and Renovate only rebases its own conflicts;
      **verify on the first real major bump** that Renovate leaves a manually-edited branch alone and the
      worker pushes to `renovate/*` (not a new `agent/*`). **P3 (later):** a longer cooldown on majors so a
      human CAN opt into an interactive LLM session for the riskiest. Relates to FU-041, FU-044, FU-014.
      **Status (2026-07-05):** the MECHANICAL sibling leg is proven live — sleep-tracking#14 (docker digest,
      `automerge`) rode `renovate-approve` → auto-merge with no LLM (that's the FU-014 half). The
      *analogous* reviewable-with-a-worker pattern is proven via the **coordinator major lane** (FU-047,
      #18: reviewer investigates → worker adapts → merge). **STILL UNPROVEN — the FU-046-specific path:** an
      armed `deps-review` Renovate PR flowing through the **review reflex** (not the coordinator) →
      CHANGES_REQUESTED → a worker adapting on the **`renovate/*` branch** (verify Renovate doesn't clobber
      its commits) → loop → merge. Awaits a real reviewable Renovate bump; keep open until one flies.
- [ ] **FU-068** — **Labels move into the AgentStack claim via `provider-upjet-github` (the
      GitHub-side permission-tier split).** Administration tier (repos/rulesets/org secrets) stays in
      out-of-jail `tofu/github` permanently — that credential never enters jail or cluster. Issues
      tier (labels, `Issues:R/W` only) becomes stack self-service: `spec.repos[].labels` on the
      claim; the Composition renders the composed label set (platform taxonomy + stack extras) per
      repo. **MECHANISM BUILT 2026-07-16** (trigger: the tofu-apply "pollution" complaint —
      label noise drowning the permission diffs): provider-upjet-github v0.19.1 installed via
      `argocd/resources/crossplane/github-provider.yaml`; creds ES + ProviderConfig
      (`github-providerconfig.yaml` — inert/SecretSyncedError until the App exists); XRD
      `repos[].labels` + Composition `IssueLabels` block with the platform taxonomy inline
      (GitHub defaults + agent state machine + Renovate lanes; mirrors labels.tf until it dies);
      `scripts/github-labels-app-bootstrap.sh` (check|manifest|catch|convert|secrets|verify —
      mints the three `LABELS_GH_APP_*` Infisical keys). **FIRST MIGRATION LIVE 2026-07-16**
      (same day): homelab-labels App installed org-wide (All repositories), creds chain green,
      and FIVE repos claim-owned — oracle-iac + oracle-fleet + allure-behavior-snippets
      (oracle claim, track/* extras; verified on GitHub: allure 9→27 labels, oracle-fleet
      complete incl. the previously-missing deps-review, nothing deleted) and agent-runtime +
      agent-coordinator (platform claim, taxonomy-only). Gotchas found live: bare hex colors
      parse as YAML scientific notation (`5319e7` → 5.319e10 — QUOTE them; XRD description
      warns), and `labels: {}` gets server-stamped to `{extra: []}` (explicit `extra: []` per
      the drift convention). **Remaining:** per-repo CLAIM-FIRST migration of the rest
      (sleep-tracking/snore-recorder/sleep-iac via the sleep claim; homelab has no claim —
      decide its home); (operator, out-of-jail) drop migrated repos from `label_repos` via
      **`tofu state rm`** (NOT destroy — it deletes the labels on GitHub and the authoritative
      claim fights back), delete labels.tf when the list empties. The generated resource is
      AUTHORITATIVE `github_issue_labels` — it deletes unmanaged labels; two managers fight.
      Design: [`docs/agents/agentstack.md`](agents/agentstack.md) §"The GitHub side". Relates
      FU-048, ADR-085.

## Monitoring & storage

- [ ] **FU-084** — **GitHub API rate-limit metrics + dashboard + alert.** Motivated by the
      2026-07-17 incident: the coordinator-git App-installation GraphQL pool (5000/hr, SEPARATE
      from REST) drained to 9 and the live review-reflex started FATAL-aborting `gh pr list`
      ("API rate limit exceeded for installation ID 142724430") — nothing was watching it, it was
      only visible in the reflex's own failure log. Extend the ONE poller
      (`argocd/resources/github-exporter/`, a `collect_rate_limits()` — `gh api rate_limit` is
      FREE, doesn't count) to emit `github_rate_limit_remaining{token,resource}` + `_limit` +
      `_reset` for BOTH the PAT and each App-installation token (coordinator-git, reviewer-git,
      merge, deploy, agents, labels, …), split `core` vs `graphql` (graphql is the one that bit us
      and is invisible on the default REST view). Then a dashboard panel (remaining/limit % +
      reset countdown per token) on `dashboard-github.json` and a PrometheusRule alert
      (`github_rate_limit_remaining / _limit < 0.1` for 5m, warning) in `prometheusrule.yaml` —
      the same file as `AgentReviewLoop`/`AgentErrorFlagged`. Prior-art: none matched "rate limit
      / graphql / quota" in FU/ADR; the exporter has no rate-limit collector today. See
      Inherited from FU-085 (built+archived 2026-07-17): once the /coordinate edge
      proves itself in live use, relax the coordinator cron `*/10 → */30` (one line in
      reflexes-argo.yaml) — the edge carries latency, the cron only sweeps. See
      [[reflex-graphql-rate-limit]] for the behavioral half (don't poll-loop the reflex). Relates
      the one-poller doctrine ([[github-exporter]]).
- [ ] **FU-082** — **wk-01 memory pressure makes Talos's OOMController serially kill BestEffort
      pods — Grafana crashlooped 21 cycles (84 restarts), argocd-application-controller 26.**
      Diagnosed 2026-07-16 (operator noticed Grafana): all four grafana containers exit 137
      SIMULTANEOUSLY + `SandboxChanged` — that's the Talos 1.13 userspace OOM controller
      SIGKILLing whole besteffort pod cgroups (`talosctl dmesg | grep "OOM controller"` — 90
      triggers on wk-01 since ≥07-13, so chronic, not today's churn). wk-01 sits at ~82% of
      11.2Gi with the platform heavies (Prometheus ~1Gi, Infisical 815Mi, UniFi 739Mi, ArgoCD
      app-controller 546Mi, Home Assistant 379Mi) and BOTH victims are QoS BestEffort — first
      in the kill order. Fix directions: (a) ✅ DONE 2026-07-16 — requests-only
      (no limits) for grafana + both sidecars + sleep-sqlite-sync (monitoring.tf) and the argocd
      application controller (argocd.tf); both pods now Burstable. (c) ✅ DONE 2026-07-16 —
      `PodSigkilled` alert (node-health group, monitoring.tf): exit-137 restarts joined to KSM
      `last_terminated_exitcode` — Talos OOM kills report reason "Error", so stock
      OOMKilled-reason alerts never see them; fired immediately on the day's residue (positive
      control, self-resolves). **(b) mostly DONE 2026-07-16 evening, forced by escalation:** the
      pressure reached BURSTABLE victims (the requests-bearing grafana pod sandbox-killed) and
      Prometheus itself sat at 76 kill-restarts (BestEffort, the biggest target — monitoring was
      blind to its own death, which is why (c) matters). Prometheus got requests
      (1200Mi, monitoring.tf) and a cordon-nudge moved UniFi→wk-02 + Infisical (app→hp-01,
      pg/redis→wk-02) off wk-01 (~1.5Gi relief; CNPG refloated cleanly). Remaining (b) residue:
      unifi-mongo + Home Assistant still on wk-01 unrequested — give them the same requests
      treatment on next touch; capacity is NOT the constraint (wk-02/hp-01 idle), a new PVE
      worker VM is a headroom/HA decision only. **CLUSTER-WIDE SWEEP DONE 2026-07-17:** the
      general missing-requests problem — a BestEffort estate gave the scheduler dishonest
      (near-empty) numbers so churn kept piling onto wk-01. Requests (sized from live `kubectl
      top`) + memory limits where bounded added to: both CNPG databases (infisical-pg/forgejo-pg
      — a BestEffort DB is unacceptable), garage, ALL argo-cd components, cilium
      operator/envoy/relay, the kube-prometheus sub-charts (node-exporter/operator/KSM),
      crossplane provider-terraform + upjet-github + both functions (DeploymentRuntimeConfig),
      the CNPG/ESO/ARC controllers, forgejo-runner. NO memory limits on DBs, repo-server, the
      terraform/upjet providers, or CI — their spikes must degrade, not OOM. **Deliberately left
      BestEffort:** Longhorn control-plane sidecars (csi-*/engine-image/manager — on storage
      nodes not wk-01, and Longhorn is resource-tuning-sensitive; instance-manager already has
      requests), infisical's bundled Redis (imperative Infisical chart, tofu/infisical), and
      transient Job/scale-set-runner pods. Relates FU-028 (same node-tier scoping theme).
- [ ] **FU-028** — Longhorn schedules manager/engine-image/instance-manager onto the ephemeral
      laptops (compute-only) → `KubeDaemonSetMisScheduled` ×2 + a stale-PDB alert. Scope Longhorn
      off the ephemeral tier (node selector / taint) or silence the two rules.
- [ ] **FU-029** — The Longhorn dashboard "Alerts" panel is empty by design (it's a Grafana
      unified-alerting list; we alert via Prometheus→Alertmanager). Optional: repoint that panel
      to a Prometheus `ALERTS{alertname=~"Longhorn.*"}` query.
- [ ] **FU-030** — Loki 7-day retention: revisit after watching usage
      (`argocd/resources/loki/loki-config.yaml`).

## Hardware & nodes

- [ ] **FU-031** — thinkcentre BIOS → disk-first (it's PXE-first, so every boot pays a PXE timeout;
      disk-first would also make a persistent matchbox flag safe again).
- [ ] **FU-032** — Watch: thinkcentre's one 1Gbps link blip since the cable fix (2026-06-11) and
      wk-metal-02's one unexplained reboot. On recurrence: chase cable/switch-port
      (thinkcentre) resp. battery/power (wk-metal-02, plug `laptop4`).
- [ ] **FU-033** — Before any Talos 1.14 upgrade: apply the `VolumeConfig secure:false` /
      `noexec` patch or `/var` breaks Longhorn v1 (warning in `tofu/longhorn.tf`).
- [ ] **FU-034** — Buy a network Zigbee coordinator (SLZB-06 class) — unblocks local radios
      (ADR-041, Open).

## One-time ops

- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
- [ ] **FU-038** — Tuya plugs: drop the cloud dependency for local-API polling; then the `/10`
      power correction can go away (`homeassistant/ha-config/packages/power.yaml`).

---

See also `ROADMAP.md` → "Backlog / parked features" (self-hosted SLSA L3 build-out, bare-metal node
suspend/resume, the caching-tier image mirror ADR-070, the edge tier).
