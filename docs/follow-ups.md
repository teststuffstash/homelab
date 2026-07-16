# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-082**.
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
      **Remaining consumers:** (a) Talos node-level `machine.registries.mirrors` (all cluster
      pulls — apply from home, verify restart semantics); (b) ci-runner-01 `daemon.json`;
      (c) ARC runner pods; (d) gate scripts actually consuming `REGISTRY_MIRROR_*` (first:
      oracle-fleet `scripts/e2e-kind.sh` via kind `containerdConfigPatches`) — now the LAST
      blocker for the full gate in-pod (FU-081 ride r3 2026-07-16: kind-NODE pulls go upstream
      docker.io, the enforced CNP drops them → garage rollout timeout; dind's own mirror config
      doesn't reach the kind node's containerd). Design caveat: recent kindest/node ships
      containerd 2.x, where the legacy `registry.mirrors` TOML is removed — use the
      `config_path` + `certs.d/hosts.toml` shape, not the old patch examples; (e) ✅ DONE
      2026-07-16 — `nixcache` LB VIP `192.168.40.23` (+ CNP belt in the agentstack Composition);
      the launcher passes `NIX_CACHE_URL=<VIP>` on docker rides (the agent-base entrypoint
      already honored the env — no agent-runtime change needed). Verify on the next kata ride:
      `devbox install` should be LAN-speed, not the ~4-min WAN fallback observed 2026-07-14.
- [ ] **FU-077** — **PodSecurity runtimeClass exemption for kata** (apiserver
      `admissionControl` patch on cp-01, Talos `cluster.apiServer`): privileged-inside-a-microVM
      is root in the guest only, but PSS can't see runtime classes — docker-mode worker
      namespaces (oracle-fleet, `argocd/platform/oracle-namespaces.yaml`) currently opt up to
      `enforce: privileged` wholesale. The exemption makes kata pods PSS-exempt surgically and
      the namespaces revert to baseline. Needs a brief apiserver restart on the single control
      plane — do it from home, not over the VPN.
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

- [ ] **FU-081** — **The FULL oracle kind gate exceeds the kata ride memory envelope — for every
      harness.** Evidence 2026-07-16 (claude validation rides, transcripts
      `s3://agent-transcripts/oracle-fleet/adhoc-fu066-kind-gate/`): with the docker client fixed
      (oracle-fleet#32), `devbox run e2e` reached the daemon and started the ingester image build,
      then **dind OOMKilled (exit 137)** — the kind node image + the running kind cluster + build
      layers all charge the dind cgroup, and `/var/lib/docker` is a 2Gi MEMORY-backed tmpfs inside
      a 2560Mi limit. The ceiling is hard: the kata spike already proved 5Gi VM + 3Gi tmpfs
      guest-OOMs and a 6Gi VM is refused by the hypervisor (8G laptops,
      `docs/spikes/kata-ci-gate.md` attempts 4/5) — and its acceptance was a MINIMAL k3d
      cluster-up, never the full gate. NB no FU/ADR matched "kind gate memory/k3d migration"
      (FU-074 archived the minimal acceptance; FU-073d is mirror consumption). **DECIDED (b)
      2026-07-16 (operator): disk-backed `/var/lib/docker` via a block PVC** — the layer store
      outgrows RAM on any full gate regardless of harness; get the shape right now, the perfect
      build machine (128G+Optane class) is a hardware decision for later. BUILT same day:
      `longhorn-scratch` StorageClass (replica=1 on the bulk disks, ADR-089 addendum) +
      agent-session.sh dind mounts a per-ride ephemeral BLOCK PVC (20Gi, volumeDevices +
      mkfs/mount preamble — virtio-blk is the one disk shape where overlay2 works in a kata
      guest) + `storage.scratch` quota knob in the AgentStack XRD/Composition. Rejected for
      now: (a) kind→k3d migration (orthogonal, still worthwhile for speed), (c) bigger node
      (hardware later). **Validated same day** (rides r2/r3, transcripts
      `s3://agent-transcripts/oracle-fleet/adhoc-fu081-scratch-pvc/`): the old OOM point is
      GONE — ingester image build + kind cluster-up both completed on the block PVC, dind
      healthy throughout. Two non-memory blockers surfaced en route: the gate script's
      context-namespace fallback (in-pod kubectl resolves empty context-ns to the SA ns →
      oracle-fleet#33, one-line fix) and kind-NODE image pulls bypassing the dind mirror into
      the egress CNP drop (= FU-073d, where the fix belongs — garage rollout timeout was an
      image pull, not memory). **Remaining:** land oracle-fleet#33 + FU-073d, then one green
      full gate in-pod retires the interim CI-only policy; consider oracle's claim declaring
      `storage: {scratch: 40Gi}` once quotas go live (claim today has no storage block =
      legacy-open). Two live fixes this exposed are in the same commit: the longhorn-csi-plugin
      DS toleration bridge (attach was impossible on ALL kata laptops) and the busybox-blkid
      mkfs guard. Relates FU-072/FU-073, ADR-082; born from FU-066's acceptance.
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
      (a) render the write-only transcripts key into each fixer ns (kills agent-session.sh's
      cross-ns read of `agent-transcripts-s3` + the "one deliberate exception" in
      agents/coordinator/rbac.yaml — no FU/ADR matched "transcripts key per-namespace");
      (b) workbench needs an explicit `openrouterkeys` read Role (the CRD lacks the `admin`
      aggregation label — same gap workbench.yaml already patched for tf.upbound.io). Docker-ride
      dispatch from the jail additionally waits on FU-072 (resolve_ep cross-ns endpoint reads).
      Also: document the stack-jail credential-airlock pattern in
      docs/agents/platform-and-stacks.md when this lands (today it lives only in script headers).
      Relates FU-045/FU-048/FU-050/FU-066.
- [ ] **FU-069** — **Propagate the anomaly protocol beyond the review path.** The `agent/error`
      circuit-breaker label + `AGENT_ERROR:` comment convention went live for reviews 2026-07-12
      (reflex breakers + reviewer self-guard + exporter `AgentReviewLoop`/`AgentErrorFlagged`
      alerts — `docs/agents/merge-path.md` §Runaway dispatch, born from the oracle-fleet#13
      12-duplicate-approval loop). **(a) coordinator half DONE 2026-07-16:** `coordinator-scan`
      excludes `agent/error` items from every actionable clause and reports them human-first;
      the brief's label table carries the rule (never dispatch/relabel/arbitrate; emit label +
      `AGENT_ERROR:` comment on self-detected loop anomalies). Remaining: (a′) worker recipes
      in the app repos' `.agents/` emit the same signal; (b) grant the
      homelab-reviewer App `issues:write` so the reviewer can apply the label itself instead of
      only commenting; (c) adopt the pre-created label into tofu (outside the jail):
      `github_issue_label.agent[<repo>::agent/error]` imports per the `labels.tf` header, then
      apply.

- [ ] **FU-018** — **BUILT + ACCEPTED 2026-07-10 (ADR-087): opaque-ref LLM creds + broker git tokens,
      acceptance green on oracle-fleet#7/PR#12 (incl. salvage-push + PR-open with zero pod
      credentials). Goose default ON since 9f12d88 (`AGENT_CRED_INJECT=0` opts out). Opencode leg
      SHIPPED 2026-07-16: under injection the session config deep-merges
      `provider.openrouter.options.baseURL=<proxy>/api/v1` over the pin, the pod key is the same
      opaque ref, and OPENROUTER_HOST rides along so agent-finalize's usage read resolves via the
      proxy — needs one live opencode ride to validate (opencode is fallback-chain-only right now).
      REMAINING: drop the env/mount fallbacks with FU-020's deny-all + that validation ride.** Original: **ADR-081 egress proxy**: inject per-job creds (git/LLM never held in the pod)
      and rewrite the OpenRouter `provider` routing (order / max_price / ignore; prefer *caching*
      providers) — the biggest cost lever. **Provider-injection v1 LIVE (2026-07-09, E2E-verified):**
      `argocd/resources/openrouter-proxy/` (ConfigMap python, ns `agent-egress`) injects the
      per-model pin into goose's chat/completions (`OPENROUTER_HOST` wired in `agent-session.sh`,
      opt-out `AGENT_OPENROUTER_PROXY=""`); opencode carries the same pin itself via per-session
      `OPENCODE_CONFIG`. ⚠ `provider.order` matches endpoint-tag base SLUGS (`atlas-cloud`), not
      display names. REMAINING here: credential minting/injection (the pod still holds its
      OpenRouter key + GH_TOKEN) — then FU-020's Cilium lockdown makes the proxy the only exit.
      Cost autopsy: `agents/README.md` → Operational findings.
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
- [ ] **FU-020** — **FIRST STACK LIVE 2026-07-10**: oracle-fleet worker pods under deny-all
      (CiliumNetworkPolicy `agent-worker-egress`, now rendered by the oracle AgentStack claim —
      allow: dns, agent-egress proxy+broker, nix-cache, garage, monitoring, GitHub/PyPI/nix FQDNs;
      NO direct openrouter.ai). Gated on ADR-087 inject default-on. **Rollout progressed
      2026-07-12 (FU-048 claims):** sleep-tracking + openrouter-operator worker CNPs LIVE in
      MONITOR (`egress.enforce: false`); `hubble.relay` + `drop:sourceContext=namespace` live
      (tofu/cilium.tf, agents rolled); `AgentWorkerEgressDropped` alert live WITH a positive
      control (deliberate forbidden egress from a labeled pod → the predicted hang →
      `hubble_drop_total{source="oracle-fleet",reason="POLICY_DENIED"}` in Prometheus).
      **VALIDATION RIDE DONE 2026-07-12**: issue #8 round 2 ran CLEAN under enforced deny-all +
      broker creds + claim-composed infra (441s, $0.0347, exit clean, key_hash in stats).
      Unclassified tail: ~150 POLICY_DENIED drops from the namespace DURING the clean ride
      (something non-essential retried against the allowlist — likely goose telemetry or a direct
      openrouter.ai attempt, which the policy exists to stop); the flow buffer rotated before
      classification — **harvest must run LIVE during a ride** (`hubble observe --follow`), noted
      for the monitor-stack harvests. Remaining: live-classify the drop source on the next ride,
      harvest+flip the two monitor stacks, then drop the env/mount credential fallbacks. Original: Cilium egress lockdown for worker pods (deny-all +
      allow the proxy and the nix cache — without the nix allowance `devbox install` hangs).
- [ ] **FU-058** — **Retro P3: the scheduled retro session** (`docs/agents/observability-and-retro.md`
      §B2). Budget-capped batched LLM retro over the worst-K ledger tasks: transcript slices via the
      MCP tools (not yet built), dated report in `docs/agents/retros/`, process-file PRs only
      (human-gated), scores its predecessor first. The FU-057 ledger it needs is LIVE (archived
      2026-07-16) and accumulating; first run hand-supervised. Absorbs FU-057's small residue:
      ledger-reflex consuming `key_hash` for the OpenRouter activity-API per-request backfill.

- [ ] **FU-063** — **(optional enrichment) `ci_state` on PRIVATE repos needs a code change —
      NO PAT scope can read their check runs.** Fully corrected 2026-07-16 (operator caught both
      wrong theories): the exporter's open-PR GraphQL queries `statusCheckRollup` on the PR head
      commit = the aggregate of **check runs** (REST: `/commits/{ref}/check-runs`) + commit
      statuses. GitHub Actions reports check runs, never commit statuses (verified: the status
      API on an oracle-fleet PR head is empty) — so `Commit statuses: read` is a no-op here and
      can be dropped. And the Checks read API supports ONLY classic-PAT `repo` scope or GitHub
      App tokens (Apps have `checks:read`) — fine-grained PATs have NO route (the endpoints are
      absent from the fine-grained-permissions doc; the "Checks: read grant" this entry briefly
      claimed does not exist). Public repos need no scope — hence agent-runtime#16 exports
      `success` while private oracle repos read `none`. Paths: (a) **join workflow-run
      conclusions by PR head SHA** — `Actions: read` (already granted) covers
      `/actions/runs?head_sha=` on private repos; add `headRefOid` to the PR query + aggregate
      in `collect_*()` (fits the one-poller doctrine, no new creds); (b) an App installation
      token for repo data (billing must stay PAT — two creds, bootstrap work); (c) classic
      `repo`-scope PAT — rejected, overbroad. Prefer (a).

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
- [ ] **FU-024** — **ENFORCED 2026-07-10 at the egress proxy** (operator writes GUARDRAIL into session
      Secrets; proxy 403s paid models on only-free INJECTED sessions before spend; unit-verified).
      Remaining: one live-fire canary (the scout's first supervised run is it). Original: Wire
      `guardrail: only-free` enforcement in the openrouter-operator (declared, not enforced). Now load-bearing for the FU-062 model scout (free canary keys must be
      honor-system no longer).
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
      **Scout first supervised run DONE + UNSUSPENDED 2026-07-16** (all three preconditions:
      bootstrap snapshot → forced-diff digest posted via coordinator-git, homelab#27 synthetic,
      closed → snapshot advanced; weekly Mon 06:00 live). NB the run did NOT exercise FU-024's
      live-fire canary — canary dispatch + key minting are still TODO in `agents/model-scout.sh`
      (report-only v1); FU-024's remainder stays open until that leg is written and one canary
      flies. OPEN: scout canary leg (+FU-024 live-fire), ADR-081 cred-injection remainder
      (FU-018) + egress lockdown (FU-020).
- [ ] **FU-026** — Graduate the coordinator from the hand-driven brief to a durable engine
      (Temporal / Argo Workflows+Events / CRD+controller) — state already lives in labels+CRs, so
      it's a mechanical swap.
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
- [ ] **FU-045** — **Coordinator context is per-STACK, not homelab-only.** `coordinator-session.sh`
      clones just `homelab`, but with the FU-025 three-layer split a stack's deploy truth lives in its
      own `-iac` repo (sleep → `sleep-iac`), so a full "sleep coordinator" context is really
      homelab + sleep-iac + the app repos — and a different stack (`idp`, …) is a different context
      (homelab + its repos). Generalize the single homelab clone into a **per-stack context** (a small
      stack manifest → which repos to clone/observe), and possibly run **one coordinator per stack**
      rather than one homelab-wide. Mostly matters as stacks multiply; today the coordinator doesn't
      need the `-iac` repo in-context because deploys are automatic (it never touches them). Relates to
      FU-026 (durable engine), FU-039 (platform self-service), and the three-layer topology.
      **First cut (2026-07-05):** `agents/stacks.json` (claim-shaped stack→repos list) + a **deterministic
      gate** `agents/coordinator-scan.sh` (`devbox run coordinator-scan`) that per-stack lists open
      issues/PRs, applies the coordinator actionability predicate, and only spawns the LLM when there's work
      (no empty wakes) + `coordinator-session.sh --stack/--repos` scoping. The stack SOURCE is one swap-point
      (`stacks_json()` → later `kubectl get agentstacks`). Design + target ownership: **FU-048** and
      [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md). **Ran live (2026-07-05):**
      the gate found sleep-tracking#18, printed the scoped `--tick` command, and the scoped opus coordinator
      drove the FU-047 major lane E2E. Also added an **orphan backstop** (gate reports un-armed/unclassified
      dep PRs — caught sleep-tracking#14/#15). **Second brick (2026-07-08):** `coordinator-session.sh` now
      **clones ALL the stack's `--repos`** into `/work/<repo>` and runs with its cwd in the stack's
      `--main-repo` (`stacks.json` `mainRepo`: oracle → `oracle-fleet`, sleep/platform → `homelab`), so the
      main repo's `CLAUDE.md` + specs load as natural cwd context (brief still absolute-pathed from
      `/work/homelab`); `coordinator-scan.sh` passes `--main-repo`. Clones are read-only reference (a direct
      write tier is **FU-059**). Remaining for full FU-045: one-coordinator-per-stack + the `AgentStack` claim
      are the **FU-048** (XRD) scope — **both resolved 2026-07-12**: claims live for all three stacks,
      the swap-point reads them (merge over the stacks.json mirror), and one GLOBAL reflex was decided
      over per-stack coordinators (agentstack.md §Decisions); the scheduled tick is **FU-050**.
- [ ] **FU-048** — **BUILT 2026-07-12, first claim = oracle (live).** XRD
      `agentstacks.platform.teststuff.net` + go-templating Composition (`argocd/resources/agentstack/`,
      functions with the providers): per fixer repo renders the git-token trio, the standing
      OpenRouterKey, the worker egress CNP (baseline+profile+extraFQDNs with the monitor→enforce dial
      below), and `agentstack-proxy-session-keys` RBAC (name ≠ the hand-list's — gapless migration).
      `stacks_json()` FLIPPED: cluster claims merged over stacks.json (probe-first fallback; reflex SA
      granted agentstacks read). Docs dual-surface: `docs/agents/agentstack.md` + the in-cluster
      `agentstack-docs` ConfigMap, discoverable from the XRD's `platform.teststuff.net/docs-configmap`
      annotation + `kubectl explain` (the FU-049 pattern seed). Gotcha for the next XRD: crossplane's
      SA holds NO RBAC for arbitrary composed kinds — aggregate a ClusterRole
      (`rbac.crossplane.io/aggregate-to-crossplane`, agentstack/rbac.yaml). Acceptance: throwaway claim
      rendered all 7 kinds + cascade-GC'd; oracle cutover live (hand files deleted from oracle-iac, CNP
      AgentStack-owned + still enforced, token minted, key re-minted, scan sources oracle from the
      cluster). **COMPLETED 2026-07-12 (second pass):** ALL THREE stacks on claims (sleep →
      sleep-iac, platform → the fixer dir; hand-list `openrouter-proxy-rbac.yaml` DELETED after
      gapless per-stack handoffs); in-cluster reflex path VERIFIED (report-only Job, same
      SA/image/clone — three stacks from claims, no fallback); stacks.json REDEFINED as the
      committed MIRROR of the claims, not deleted (CI's registration-lint universe + the
      probe-failed belt — ADR-085's build-time question resolved; generating it FROM claims is
      FU-049's catalog problem). DECIDED: one GLOBAL coordinator-reflex (per-stack CronJobs only
      if cadence/isolation ever diverges — a Composition addition); GitHub-side + `.agents/`
      recipes stay OUTSIDE the claim (in-cluster GitHub-admin creds need their own ADR; recipes
      are repo content — see agentstack.md §Decisions). REMAINING: FU-065's test-cluster tier as
      a policy field when rung 2 lands. Original:
      **Agents framework = a PLATFORM CAPABILITY published as a Crossplane XRD; stacks own
      their policy.** homelab publishes an `AgentStack` XRD + Composition (renders a stack's coordinator
      gate/CronJob + review-reflex + RBAC + secret wiring = the MECHANISM); each stack's `-iac` repo declares
      `kind: AgentStack` (its repos, model tiers, tools, git workflow, review rubric = the POLICY). Migrate
      `agents/stacks.json` → a per-stack claim in the `-iac` repo and flip `coordinator-scan.sh`'s
      `stacks_json()` to `kubectl get agentstacks`. Mechanism=platform, policy=stack — same lens as ADR-084.
      **Egress requirement (2026-07-12, the FU-020 rollout design):** the Composition renders each fixer
      repo's worker CiliumNetworkPolicy from *baseline + ecosystem profile + extraFQDNs* with an
      **`enforce` dial** — `false` = monitor (`enableDefaultDeny.egress: false`: DNS visibility + the
      allowlist evaluated, nothing blocked; harvest Hubble flows over real rides, diff three-valued
      ALLOWED/WOULD-DROP/PROBE-FAILED per the meta-5 probe principle), `true` = deny-all. A new stack
      onboards in monitor and flips the field after K clean rides; a
      `hubble_drop_total{reason=POLICY_DENIED}` alert on agent namespaces makes enforcement drops loud
      (a missing allowance manifests as a HANG, per the FU-020 nix-cache finding). Enabling
      `hubble.relay` is the harvest prereq (flows are per-node + ring-buffered without it).
      Design: [`docs/agents/platform-and-stacks.md`](agents/platform-and-stacks.md), ADR-085. Relates FU-045/039/020.
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
