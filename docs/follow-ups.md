# Follow-ups (the FU tracker)

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Bigger
parked *features* live in `ROADMAP.md` → "Backlog / parked features"; this file is the operational
tracker.

**Conventions (the contract):**

- Every item has a stable id **`FU-NNN`** (3 digits, sequential, **never reused**).
  Next free id: **FU-040**.
- **This file is the only tracker.** Everywhere else — docs, code comments, commit messages —
  reference the id (e.g. `FU-007`), never a free-floating `TODO`. Detailed context may stay near
  the code/doc it concerns; the item here carries the one-liner and links to the detail.
- **Resolving an item:** `git grep FU-NNN`, then delete the item here **and every reference**, in
  the same commit as the fix. `devbox run follow-ups-lint` flags references to ids that no longer
  exist here.
- **Adding an item:** next free id, into the fitting theme section (ids don't encode theme), bump
  the counter above.

_Last updated: 2026-07-02._

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
- [ ] **FU-006** — Retire the obsolete `SLEEP_FORGEJO_REGISTRY_TOKEN` Infisical key (ghcr cutover
      done 2026-06-25).

## GitOps & platform

- [ ] **FU-007** — **ArgoCD → Forgejo cutover** (offline-resilience goal). Prereq: pull-mirror the
      **homelab** repo itself into Forgejo (the `sleep-lab` org mirrors exist since 2026-06-21).
      Then flip `var.argocd_repo_url` + child-app `repoURL`s and deliver the Forgejo read cred via
      ESO. Procedure: `argocd/README.md` → "Forgejo cutover".
- [ ] **FU-008** — Forgejo orgs/mirrors were created imperatively (one-shot token, since deleted).
      Decide: codify via the Forgejo TF provider vs accept the imperative bootstrap.
- [ ] **FU-009** — Verify the `platform` root app's cosmetic OutOfSync is gone after the
      `ignoreDifferences` fixes in `tofu/argocd.tf`; drop this item if so, tidy if not.
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

## CI & dependency automation

- [ ] **FU-014** — **Renovate (auto-update PRs) — not set up anywhere yet**, though `ROADMAP.md`
      (agent P2), `docs/ci.md` and `docs/agents/README.md` all assume it. Scope: image/chart/action
      bumps on the app repos + homelab, gated by the existing CI (later the full-stack gate,
      ADR-082).
- [ ] **FU-015** — Custom ARC runner image: bake `xz`/`gh`/devbox + a warm nix store (kills the
      per-job `apt-get` and the ~5 min cold start), and wire the in-cluster nix cache as a
      substituter for runner pods. `docs/ci.md` → "residual costs".
- [ ] **FU-016** — SLSA Phase-1: cosign signing + SBOM + scan on the hosted runners (both tiers).
      Plan: `docs/slsa.md`.
- [ ] **FU-017** — Merge the two runner GitHub Apps (`homelab-arc-…` + `homelab-runner-registrar`)
      — both need only org self-hosted-runners R/W. `docs/github-setup.md` §2.

## Agents

- [ ] **FU-018** — **ADR-081 egress proxy**: inject per-job creds (git/LLM never held in the pod)
      and rewrite the OpenRouter `provider` routing (order / max_price / ignore; prefer *caching*
      providers) — the biggest cost lever. Interim: `opencode.json` `options.provider`. Cost
      autopsy: `agents/README.md` → Operational findings.
- [ ] **FU-019** — Migrate the worker plain `Pod` → agent-sandbox `Sandbox` CR (ADR-078).
      `agents/agent-session.sh`.
- [ ] **FU-020** — Cilium egress lockdown for worker pods (deny-all + allow the proxy and the nix
      cache — without the nix allowance `devbox install` hangs).
- [ ] **FU-021** — goose retry policy: hard-stop on auth/limit errors (it retried a
      budget-exhausted 403 812×).
- [ ] **FU-022** — Pin tool versions in `agent-base` + project `devbox.json` so the baked-toolchain
      cache hits land (`@latest` drifts vs the project lock and re-fetches).
- [ ] **FU-023** — Stats v2: per-request token breakdown via the OpenRouter *activity* API + a
      cross-run Grafana dashboard over the `AGENT_RUN_STATS` Loki lines.
- [ ] **FU-024** — Wire `guardrail: only-free` enforcement in the openrouter-operator (declared,
      not enforced).
- [ ] **FU-025** — **Deploy-versioning + repo-structure rework**: the release→deploy path is
      manual and drifty (`Chart.yaml` vs the `v*` tag vs ArgoCD `targetRevision`). Blocks
      automating coordinator step 7a (`agents/coordinator/README.md`). **Direction (2026-07-02):
      a per-stack `sleep-iac` repo** — the ArgoCD AppProject + app-of-apps for the sleep stack
      (today's homelab `argocd/sleep/` + values + the apps' `infra/` CRs move there) — so app
      repos stay platform-agnostic (standard Helm/Secrets/S3/Postgres, publish image+chart only)
      and a deploy = a version-bump PR in `sleep-iac` with its own CI gates; homelab keeps just
      the platform + a root Application pointing at `sleep-iac`. Homelab-as-a-platform, like
      AWS/Civo. **Full extraction blueprint: [`docs/sleep-iac.md`](sleep-iac.md).**
- [ ] **FU-026** — Graduate the coordinator from the hand-driven brief to a durable engine
      (Temporal / Argo Workflows+Events / CRD+controller) — state already lives in labels+CRs, so
      it's a mechanical swap.
- [ ] **FU-027** — One fresh-issue live run to demo the PR stats comment end-to-end (both halves
      are validated separately).
- [ ] **FU-041** — **Agent PRs that fall behind master stall silently**: the ruleset requires an
      up-to-date branch (`strict_required_status_checks_policy`, `tofu/github/repo_rulesets.tf`)
      but nothing updates PR branches (`allow_update_branch=false`), so auto-merge never fires on
      a behind PR. **Direction (2026-07-03): deterministic CI serializer — no LLM in the merge
      path.** Full design (options table, diagrams, S/M/L worked examples, platform-scale
      extrapolation to multiple IDP-sized stacks, rollout phases):
      **[`docs/agents/merge-path.md`](agents/merge-path.md)**. Shape: worker arms auto-merge;
      per-repo updater workflow (`adRise/update-pr-branch`, update-before-review) keeps one
      head-of-line PR current; reviewer dispatched only when green+current+unapproved (one review
      per PR); GitHub auto-merge completes. Team-plan-only features → identical for private and
      public repos. Coordinator stays the issue's owner start-to-finish but as a tool-less
      overseer: mechanical transitions run as its deterministic reflexes (updater workflow +
      review-reflex CronJob), the LLM is consulted only at judgment points (conflict, round
      limit, stale-red) and only ever delegates. Ruled out (details in the doc):
      GitHub merge queue (Enterprise-Cloud-only on private + split process), coordinator-LLM
      merging, `allonsy-studio/actions-pr-auto-update` (hard-skips bot-authored PRs).

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

- [ ] **FU-035** — Click-op: disable ISC DHCPv4 in the OPNsense UI (stopped but still `enable=1`
      in config.xml; no API) for reboot-safety. `docs/runbook.md` → LAN DHCP.
- [ ] **FU-036** — AWS cleanup: delete the orphaned Route53 hosted zone `ZCGRPARGVE3CW` (+ the
      leftover ACM/Sectigo certs its `_*` validation records imply). Needs admin SSO (the jail key
      is read-only). Recipe: `docs/cloudflare.md`. Optionally do it as the first `tofu/aws/` root
      (which would also adopt the audit user, `scripts/aws-bootstrap-audit-user.sh`).
- [ ] **FU-037** — Investigate the standing `kubernetes_deployment.ha` tofu plan drift (a manual
      live change?); reconcile into git or accept it.
- [ ] **FU-038** — Tuya plugs: drop the cloud dependency for local-API polling; then the `/10`
      power correction can go away (`homeassistant/ha-config/packages/power.yaml`).

---

See also `ROADMAP.md` → "Backlog / parked features" (self-hosted SLSA L3 build-out, bare-metal node
suspend/resume, the caching-tier image mirror ADR-070, the edge tier).
