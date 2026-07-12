# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-069**.
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

_Last updated: 2026-07-12._

## Secrets (the "secret cleanup" track)

- [ ] **FU-001** — Consolidate imperative secrets into the platform (`docs/secrets.md` tiers):
      the `coordinator-claude` Secret (`CLAUDE_CODE_OAUTH_TOKEN`, kubectl-created —
      `agents/coordinator/README.md`) → Infisical/ESO; the `~/.claude/homelab-*` flat-file sprawl
      (opnsense, pve-ssh, matchbox, ha, droplet, cloudflare, aws, forgejo, garage, github-arc)
      → KeePass Tier-0 or Infisical.
- [ ] **FU-002** — The jail GitHub PAT is embedded in the git remote URL (visible in
      `git remote -v`); move it to a git credential helper.
- [ ] **FU-003** — HA `refresh_token` is dead (`invalid_grant`; falling back to `prometheus_llat`).
      Regenerate the refresh/long-lived token (recipe: `docs/runbook.md` → Home Assistant).
- [ ] **FU-004** — Rotate the broad bootstrap `root@pam!tofu` Proxmox token to a scoped `tofu@pve`
      token (`tofu/README.md` has the `pveum` recipe).
- [ ] **FU-005** — Decide whether an Infisical break-glass second admin is worth codifying (one
      super admin today, signups disabled).

## GitOps & platform

- [ ] **FU-007** — **ArgoCD → Forgejo cutover** (offline-resilience goal). Prereq: pull-mirror the
      **homelab** repo itself into Forgejo (the `sleep-lab` org mirrors exist since 2026-06-21).
      Then flip `var.argocd_repo_url` + child-app `repoURL`s and deliver the Forgejo read cred via
      ESO. Procedure: `argocd/README.md` → "Forgejo cutover".
- [ ] **FU-008** — Forgejo orgs/mirrors were created imperatively (one-shot token, since deleted).
      Decide: codify via the Forgejo TF provider vs accept the imperative bootstrap.
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
- [ ] **FU-015** — Custom ARC runner image: bake `xz`/`gh`/devbox + a warm nix store (kills the
      per-job `apt-get` and the ~5 min cold start), and wire the in-cluster nix cache as a
      substituter for runner pods. `docs/ci.md` → "residual costs".
- [ ] **FU-016** — SLSA Phase-1: cosign signing + SBOM + scan on the hosted runners (both tiers).
      Plan: `docs/slsa.md`.
- [ ] **FU-017** — Merge the two runner GitHub Apps (`homelab-arc-…` + `homelab-runner-registrar`)
      — both need only org self-hosted-runners R/W. `docs/github-setup.md` §2.

## Agents

- [ ] **FU-064** — **BUILT 2026-07-09 night (agent-runtime 09cd3e0 → pinned 2026.7.9-g09cd3e0d6542;
      homelab af8e2e1) — pending the acceptance round on oracle-fleet#1, then resolve.** Original scope:
      **Slow-cheap models break every freshness assumption at once — two deterministic
      fixes before FU-018's endgame.** Live evidence (2026-07-09 meta-session 2, oracle-fleet#1: THREE
      attempts, three different walls — git-token 60-min TTL, key-expiry PATCH bug openrouter-operator#6,
      $0.50 session budget at 65 min — zero model/task failures, ~2.5h of green work lost unpushed;
      full autopsy in `agents/coordinator/TICK-LOG.md`). (a) **Harness-owned terminal push**: the
      push-early recipe rule failed to bind on 3 runs / 2 models — `agent-finalize` (already runs
      post-harness in-pod) must `git push` any local branch with commits at terminal time, so a died
      run always leaves a resumable branch (kills the "hoping the worker pushes" class). (b) **Git
      token as volume mount, not env**: `GH_TOKEN` is a `secretKeyRef` env var → frozen at pod start →
      ESO refreshes can never reach a running pod; mount the Secret and read at use time (credential
      helper / finalize-time `gh auth`) so pushes always hold a live token. Both are small; FU-018's
      proxy cred-injection supersedes (b) eventually. Relates FU-019 (persistent workspace = the
      salvage/warm-resume cache on top), FU-021/FU-062 (strike classes these deaths produce).
- [ ] **FU-065** — **In-sandbox test clusters for operator-shaped repos (decided 2026-07-09: rungs 1+2).**
      Operator repos (openrouter-operator: helm install + kyverno chainsaw) need a cluster in the WORKER's
      inner loop — the CI-push cycle is too slow for writing/iterating those tests. Rung 1: **envtest +
      chainsaw** (etcd+apiserver as plain processes, unprivileged, in-pod; chainsaw takes any kubeconfig;
      covers API-level operators fully — openrouter-operator's world is CRs/Secrets/HTTPS). Rung 2:
      **vcluster** when test workloads must actually run (unprivileged; syncer runs them on the HOST
      cluster → needs a quota'd + NetworkPolicy-fenced sandbox ns per worker; FU-019-adjacent). Ruled
      out for now: kind-in-rootless-podman in an unprivileged pod (nested systemd/kubelet + cgroup
      delegation + /dev/fuse); remote-docker DinD only if node semantics ever genuinely needed.
      Test-cluster tier = a per-stack `AgentStack` policy field (ADR-085/FU-048). First consumer:
      openrouter-operator's fixer onboarding (FU-052).
- [ ] **FU-066** — **claude-code + Haiku worker tier — SUBSCRIPTION ONLY, gated on FU-018 (decided
      2026-07-09).** Add `--harness claude` to `agent-session.sh` (coordinator/reviewer plumbing already
      runs Claude Code in-pod) with Haiku as the model, on the Claude subscription (explicitly NOT
      API/OpenRouter pay-per-token). Value, mapped to the meta-session-2 failure classes: Edit/Write
      tools chunk writes structurally (kills the 15k single-tool-call truncation class), fast enough for
      every TTL window, OAuth doesn't die mid-run like minted keys, ~$0 marginal cost. Chain position:
      the RELIABLE tier before `agent/blocked`, not the default (the cheap-model experiment continues
      ahead of it). **Hard prereq: FU-018 cred injection** — the subscription OAuth token is an unscoped
      whole-subscription credential and must never sit in a worker pod env; the proxy injects it per
      request. Also needs: recipe translation (`.agents/fix.yaml` → `--append-system-prompt`), a
      subscription-usage stand-in for `cost_usd` in AGENT_RUN_STATS (tokens/turns, not $), and turn caps
      as the budget-ceiling substitute (no per-task $ cap exists on subscription — loop-safety breaker
      #2 must be re-derived from rate-limit + turn bounds).
- [ ] **FU-018** — **BUILT + ACCEPTED 2026-07-10 (ADR-087): opaque-ref LLM creds + broker git tokens,
      acceptance green on oracle-fleet#7/PR#12 (incl. salvage-push + PR-open with zero pod
      credentials). Goose default ON since 9f12d88 (`AGENT_CRED_INJECT=0` opts out). REMAINING:
      drop the env/mount fallbacks with FU-020's deny-all, opencode leg.** Original: **ADR-081 egress proxy**: inject per-job creds (git/LLM never held in the pod)
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
- [ ] **FU-057** — **Retro P2: the retro-facts reflex + cross-run dashboard**
      **BUILT 2026-07-09 (agent-runtime `fu057-exit-status-metrics` + homelab `fu057-fu061-observability`) —
      pending merge + deploy (agent-base image build/pin, ArgoCD sync of pushgateway/dashboards/viewer)
      + a post-deploy first-render confirmation; delete this item + refs once green.**
      **Polish 2026-07-10:** AgentRunNegativeCost + AgentRunInfraDeathBurst PrometheusRules (524c331);
      KEY_HASH durable end-to-end operator→Secret→launcher env→finalize stats (7224d20, operator
      3510362, runtime bd6b84b) — first live appearance in oracle-fleet#8's run stats. REMAINING small:
      ledger-reflex actually consuming `key_hash` for the OpenRouter activity-API backfill. Delivered:
      `exit_status`+`error_class` classifier (validated against the 4 real oracle-fleet runs → 2 clean,
      1 harness-death, 1 auth-storm), pushgateway + `agent_run_*` metrics push, the three dashboards
      (running-agents incl. the stall detector, model-health, cost), goose sessions.db merge in the
      viewer sync (worker sessions render turn-by-turn, verified on real data), and `agents/ledger.py` +
      `ledger-reflex` CronJob (`_ledger.jsonl`, tested against issue #1 → 4 rounds/$0.248/~3.8h). The
      stall detector's PR-state source needs FU-063 (PAT scope). Original scope below.
      (`docs/agents/observability-and-retro.md` §B1; absorbs the old FU-023 "stats v2"). On a task's
      terminal label, deterministically append one line to `agent-transcripts/_ledger.jsonl` (cost vs
      estimator band, rounds, retry storms, CI red/green, wall time, cache-hit %, tokens/request —
      per-request splits via the OpenRouter *activity* API) + a Grafana dashboard over the ledger.
      P0/P1 (capture + viewer) are LIVE — the manifests this computes from already accumulate.
      **Scope sharpened (2026-07-09 measurement, docs/agents/observability-and-retro.md §A′/§B1):**
      add `exit_status`+`error_class` to AGENT_RUN_STATS (clean/ci-failed/harness-death/auth-storm/
      budget-403/timeout); dashboards = (a) **model-health** pivot (model × success-rate/
      harness-death/$-per-successful-issue → the blacklist signal — deepseek-v4-flash died 2/4),
      (b) **running-agents** (pods by role×phase, kube-state-metrics), (c) **cost** (push worker
      cost_usd to Prometheus; coordinator/reviewer already via A0 OTLP). Highest-leverage speed
      work: this makes invisible stalls (the 2.5h reviewer block) visible — caching (FU-022) did
      NOT help the measured runs (warm nix). Also: upload goose sessions.db so the viewer renders
      worker sessions natively (no converter — it reads goose+opencode formats).
- [ ] **FU-058** — **Retro P3: the scheduled retro session** (`docs/agents/observability-and-retro.md`
      §B2). Budget-capped batched LLM retro over the worst-K ledger tasks: transcript slices via the
      MCP tools (not yet built), dated report in `docs/agents/retros/`, process-file PRs only
      (human-gated), scores its predecessor first. Needs FU-057's ledger; first run hand-supervised.
- [ ] **FU-061** — **Unify the transcript taxonomy so the viewer groups by issue/project, not cwd.**
      **BUILT 2026-07-09 (homelab `fu057-fu061-observability`, alongside FU-057) — pending merge + deploy.**
      Delivered: reviewer resolves PR→issue via `closingIssuesReferences` (verified PR#5→#1), coordinator
      keys `<mainRepo>/_ticks/`, agent-finalize adds `issue`, and the sync rewrites each jsonl `cwd` +
      each goose session's `working_dir` to a single project-qualified segment `/<project>--issue-<N>`
      so all of an issue's sessions collapse into one group (verified on the real issue-1 slice: 4 goose
      worker sessions + the reviewer's claude jsonl regroup correctly). NB deviation from the original
      cwd string below: the deployed cchv labels by cwd *basename*, so the leaf is `<project>--issue-<N>`
      (grouping) with role-round in the filename + goose session name, not `/<project>/issue-<N>/<role>-rN`
      (which would scatter under basename-labelling). Original spec below.
      Live problem (2026-07-09, screenshot): the viewer shows 7× "homelab", N× "oracle-fleet", "repo" —
      it **derives its label from the jsonl `cwd` field**, ignoring our `<proj>--<task>` sync dir names,
      AND the bucket keys scatter one issue's work across three top-level names (workers
      `oracle-fleet/issue-N`, reviewer `oracle-fleet/pr-M`, coordinator `oracle/tick-ts` — the
      stack-vs-project split, old finding F). Fix, two parts: **(1) one key**
      `<project>/issue-<N>/<role>-r<round>-<ts>/` everywhere — project = the repo always; reviewer
      resolves PR→issue via "Fixes #N"; pure-reconcile ticks that dispatch nothing → `<project>/_ticks/`.
      Manifest carries {project, issue, role, round}. **(2) sync rewrites `cwd`**: since the viewer keys
      on cwd, the sync sets each synced jsonl's cwd to `/<project>/issue-<N>/<role>-r<round>` (from the
      sibling manifest) → all of issue N's coordinator+worker+reviewer sessions group under one
      `oracle-fleet · issue-1` project, each session labelled by role-round. Touches: agent-finalize +
      reviewer/coordinator launchers (bucket path + manifest fields + PR→issue resolution),
      transcripts-viewer.yaml sync. Pairs with FU-057's goose-sessions.db upload (same agent-finalize).

- [ ] **FU-063** — **(optional enrichment) Grant the github-exporter PAT `Commit statuses: read` (or
      `Checks: read`) so the stall detector sees CI-green.** DONE 2026-07-09: `Pull requests: read` was
      granted, so `collect_open_prs()` now emits `github_pull_request_open` with `review_decision` — the
      stall detector works on review-state (unapproved PR + no reviewer pod). Measured that the PR's
      `statusCheckRollup` (CI state) needs a SEPARATE scope the PAT still lacks — the collector tolerates
      that (partial GraphQL data → `ci_state="none"`), and the dashboard filter is `ci_state=~"success|none"`
      so it degrades to "not known-red" rather than reading 0. Granting `Commit statuses: read` (GitHub-
      Actions CI reports via commit statuses under a fine-grained PAT; there is no plain "Checks: read" in
      the UI for this) upgrades it to true CI-green with no code change. Out-of-jail, operator; then the
      `ci_state="failure"/"pending"` rows populate.

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
      OPEN: scout first supervised run + unsuspend, ADR-081 cred-injection remainder (FU-018) +
      egress lockdown (FU-020).
- [ ] **FU-026** — Graduate the coordinator from the hand-driven brief to a durable engine
      (Temporal / Argo Workflows+Events / CRD+controller) — state already lives in labels+CRs, so
      it's a mechanical swap.
- [ ] **FU-042** — **BUILT 2026-07-09 night (af8e2e1): hard launcher pre-flight refuses dispatch on
      open-linked-PR / Running worker / near-dead key — resolve after the acceptance round exercises
      it.** Original: **Coordinator double-dispatches an already-in-progress issue** (no deterministic
      idempotency). The dispatch guard is soft LLM-judgment in the brief (`agents/coordinator/README.md`
      step 1: "pick one labelled `agent/queued`"), enforced by nothing. Live failure 2026-07-03:
      sleep-tracking#10 was claimed correctly (`agent/queued`→`agent/in-progress`, PR #11 opened), then
      a second coordinator pass ~3h later re-picked the same **`agent/in-progress`** issue, commented a
      fresh "round 1" unaware of #11, and opened a conflicting **PR #12** (both edit
      `tests/integration/fixtures/nights.yaml`). Closed #12, kept #11. The brief *states* the invariant
      "idempotency key `(issue, base-sha, round)` so a re-list never double-spawns" but a stateless LLM
      ignored it. **Fix: make dispatch idempotent deterministically** — refuse to dispatch if the issue
      already has an open linked agent PR **or** carries `agent/in-progress` (a hard pre-flight in
      `agent-session.sh`, or fold dispatch into a reflex like the review path — same philosophy as
      FU-041). Tightening the brief wording alone is insufficient (that's the guard that just failed).
- [ ] **FU-043** — **Auto-merge arming (+ stats comment) is coupled to the dispatcher's lifetime**, so
      an interactively-dispatched PR can be born un-armed and stall silently. `agent-session.sh`'s
      post-run block (arm auto-merge + post the `AGENT_RUN_STATS` PR comment) runs **in the dispatching
      process and blocks until the worker pod finishes (~5 min)**. A **headless** coordinator pass
      (`--run …`) runs it to completion; an **interactive** dispatch that detaches before the worker
      ends skips it entirely. Live proof 2026-07-03: sleep-tracking#11 (dispatched interactively) got
      **no** stats comment and **no** auto-merge (armed by hand at 19:41), while #12 (headless pass) got
      both. Arming is the load-bearing one — an un-armed PR is invisible to the entire merge path
      (updater/reflex/auto-merge) and stalls with no signal. **Fix: make arming independent of the
      dispatcher** — e.g. arm from a reflex/CronJob (arm any open agent PR that isn't armed), or have
      the worker arm its own PR at open (it already has `pull_requests:write`), so it never depends on
      the interactive session surviving. Relates to FU-041 (deterministic merge path) and the
      dispatch-idempotency gap in FU-042.
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
- [ ] **FU-068** — **Labels move into the AgentStack claim via `provider-upjet-github` (the
      GitHub-side permission-tier split).** Administration tier (repos/rulesets/org secrets) stays in
      out-of-jail `tofu/github` permanently — that credential never enters jail or cluster. Issues
      tier (labels, `Issues:R/W` only) becomes stack self-service: `spec.repos[].labels` on the
      claim; the Composition renders the composed label set (platform taxonomy + stack extras) per
      repo. Steps: dedicated labels GitHub App (Issues:R/W, org-wide install — the one click) →
      PEM into Infisical/ESO → ProviderConfig → install `provider-upjet-github` (v0.19.x, wraps
      terraform-provider-github v6.6.0) → extend XRD+Composition → migrate per repo *claim-first*
      (composed `IssueLabels` synced, THEN drop the repo from `label_repos` — the generated resource
      is AUTHORITATIVE `github_issue_labels`, it deletes unmanaged labels; two managers fight).
      Design: [`docs/agents/agentstack.md`](agents/agentstack.md) §"The GitHub side". Relates
      FU-048, ADR-085.
      **Status (2026-07-05):** the MECHANICAL sibling leg is proven live — sleep-tracking#14 (docker digest,
      `automerge`) rode `renovate-approve` → auto-merge with no LLM (that's the FU-014 half). The
      *analogous* reviewable-with-a-worker pattern is proven via the **coordinator major lane** (FU-047,
      #18: reviewer investigates → worker adapts → merge). **STILL UNPROVEN — the FU-046-specific path:** an
      armed `deps-review` Renovate PR flowing through the **review reflex** (not the coordinator) →
      CHANGES_REQUESTED → a worker adapting on the **`renovate/*` branch** (verify Renovate doesn't clobber
      its commits) → loop → merge. Awaits a real reviewable Renovate bump; keep open until one flies.

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
