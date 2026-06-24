# Follow-ups & in-progress

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Most
features land complete + committed; this captures the "come back to it" items so they don't get
lost. Bigger parked features live in `ROADMAP.md` → "Backlog".

_Last updated: 2026-06-17._

## GitOps & secrets (ArgoCD / CloudNativePG / Infisical / ESO) — LIVE; follow-ups

The stack is live and reconciling (ADR-005/046/062, `docs/secrets.md`, `argocd/README.md`). Loose ends:

- [ ] **ArgoCD → Forgejo cutover** — ArgoCD is sourced from **GitHub** for now (no Forgejo/Postgres
      dependency on its own git source). To honor the offline principle, mirror the repo into Forgejo
      (see the Forgejo section below) and flip `var.argocd_repo_url` + the child-app `repoURL`s, then
      deliver the Forgejo read cred via ESO. Procedure in `argocd/README.md` "Forgejo cutover".
- [ ] **`platform` root app shows OutOfSync/Healthy** — cosmetic app-of-apps self-diff (ArgoCD
      normalising the child `Application` specs), not real drift. Tidy if it gets noisy.
- [ ] **CNPG self-signed TLS** — Infisical↔Postgres uses `sslmode=disable` (node-pg rejects CNPG's
      self-signed cert). Fine pod-to-pod; revisit if Cilium transparent encryption is wanted.
- [ ] **Second admin / break-glass** — one Infisical super admin for now (signups disabled). Decide
      whether a break-glass second admin is worth codifying.

## App-owned resources via Crossplane (ADR-076) — LIVE; refinements

provider-terraform reconciles Garage buckets/keys from `Workspace` CRs (snore-recorder is the first
app: `sleep-snore` + write key, reconciled via ArgoCD, key published to Infisical). Loose ends:

- [x] **Writer key → Infisical is now GitOps** (2026-06-17) — **not** via ESO PushSecret (the ESO
      Infisical provider is **read-only**: `ClusterSecretStore` reports `ReadOnly`). Instead the
      snore-recorder **Workspace publishes it itself** via the Infisical TF provider
      (`infisical_secret`), authed by the `crossplane-tf-writer` UA identity injected into the
      provider pod. Replaces the manual `infisical-secret` step.
- [x] **sleep-tracking migrated** (2026-06-17) — Crossplane Workspace that **adopts** the live
      buckets/keys/grants via config-driven `import` (deletionPolicy: Orphan — sleep-db history
      preserved); keys published to Infisical from the old state; `sleep-ingester-credentials`
      delivered via ESO ExternalSecret. (Both apps now on ADR-076.)
- [ ] **`provider-terraform` package pinned to a digest** — currently the `:v1.1.1` tag.

## Forgejo (self-hosted Git) — minimal trial is LIVE; next steps deferred

Running minimally to try it out (`tofu/forgejo.tf`): Forgejo 15.0.3 (chart 17.1.1), built-in
**SQLite + in-memory** sessions/cache, 1 replica, 5Gi Longhorn PVC, BGP VIP `192.168.40.15`, HTTPS
at **https://forgejo.teststuff.net** (OPNsense HAProxy + Let's Encrypt).
Admin: `forgejo_admin` / `tofu -chdir=tofu output -raw forgejo_admin_password`.

When investing further (roughly in order):

- [x] **Disable open registration** — `gitea.config.service.DISABLE_REGISTRATION = true` (applied
      2026-06-12). Admin creates users now (`forgejo_admin` + the new `rasmus`).
- [x] **SSH clone** (2026-06-12) — `forgejo-ssh` is now a LoadBalancer sharing VIP `.40.15` (Cilium
      LB-IPAM sharing-key), exposed on `forgejo.teststuff.net:22` via a new **HAProxy TCP-passthrough**
      frontend (extended the `opnsense-haproxy` role with `haproxy_tcp_services`). `tea@latest` added
      to devbox. User `rasmus` (public, soot.rasmus@gmail.com) in private org `rasmus-personal`, with
      ed25519 SSH + GPG signing keys uploaded; key material in `~/.claude/homelab-forgejo/`.
- [ ] **External Postgres** — the chart dropped bundled postgres (v14), so SQLite is the trial DB.
      **CloudNativePG is now LIVE** (ADR-046) — give Forgejo its own CNPG `Cluster` and point it at it
      (`gitea.config.database.*`); migrate the SQLite data or start fresh.
- [~] **GitHub → Forgejo mirroring** — Forgejo pull-mirrors so a local copy of the GitHub repos
      survives GitHub being down. This is the prerequisite for the **ArgoCD → Forgejo cutover** (see the
      GitOps & secrets section above) — the ArgoCD-resilience goal: don't be hostage to GitHub uptime.
      **Started (2026-06-21):** private org **`sleep-lab`** holds pull-mirrors of the two private GitHub
      repos `teststuffstash/{sleep-tracking,snore-recorder}` (8h interval, releases on / issues+PRs+wiki
      off), authed with the jail GitHub PAT. Created imperatively via the Forgejo migrate API (a one-shot
      `org-mirror-setup` token with `write:organization,write:repository` scopes, since deleted; the
      standing `rasmus` `~/.claude/homelab-forgejo/api-token` lacks org scopes). The earlier manual
      `rasmus/snore-recorder` push is left in place. Still TODO: mirror the **homelab** repo itself
      (the actual ArgoCD-cutover prerequisite) and decide whether to codify org/mirror creation (Forgejo
      TF provider) vs. keep it imperative like the `rasmus`/`rasmus-personal` bootstrap.
- [~] **Forgejo Actions runner** (`act_runner`) — DEPLOYED (`tofu/forgejo-runner.tf`, ephemeral
      laptop tier, DinD). **Repurposed: this is now the Tier-B engine** — for fully-private
      **Forgejo-only** projects (Forgejo git + act_runner + Forgejo registry, self-contained).
      **Tier-A** (GitHub-canonical) projects — sleep-tracking, snore-recorder — moved to a self-hosted
      **GitHub** runner instead (see below). The CI seam is unchanged: workflows just call
      `devbox run <task>`, so the same logic runs under either forge. **Two-tier model is documented
      in [`docs/ci.md`](ci.md).** SLSA Phase-1 (cosign + SBOM on top of the hosted runner) still TODO —
      see [`slsa.md`](slsa.md).

## CI — GitHub-canonical tier (ARC + ghcr) — LIVE

The two GitHub-canonical repos carry thin `.github/workflows/` that call `devbox run <task>`
(`ci` / `test-chart` / `scan-secrets` / build→ghcr), `runs-on: homelab-ephemeral`. **The ARC runner
is live and CI is green** (sleep-tracking PR #1). Key gotchas now resolved + load-bearing:

- [x] **Nix in the ARC pod** (2026-06-24) — the runner is a *container* (no systemd), so devbox's
      daemon-based installer fails ("docker shim → exit 125"). Fix: install **single-user** Nix
      (`cachix/install-nix-action@v31` `--no-daemon`) + `devbox skip-nix-installation`, and apt-install
      `xz` (the slim `actions-runner` image lacks it). See [`docs/ci.md`](ci.md). Follow-ups: a custom
      runner image (bake `xz`/`gh`/devbox + warm store) to kill per-job apt + the ~5min cold install,
      and a LAN Nix substituter so jobs don't hit the WAN.
- [x] **OCI release flow** (2026-06-24) — `release.yaml` on a `v*` tag builds + pushes the image AND
      the Helm **chart** to ghcr (`oci://ghcr.io/teststuffstash/charts`, chart version == appVersion ==
      git tag; `scripts/package-chart.sh`). **sleep-ingester is deployed from the OCI chart** (v0.2.0):
      `argocd/sleep/sleep-ingester.yaml` source 1 = `ghcr.io/teststuffstash/charts` chart
      `sleep-ingester`. Chart package is **public** (ArgoCD pulls anonymously); image stays private.
      **Release procedure:** tag `vX.Y.Z` → release.yaml publishes → bump `targetRevision` + image `tag`
      in homelab → ArgoCD syncs.
- [x] **`sleep` app-of-apps drift** (2026-06-24) — it had fallen out of the live `argocd-apps` release
      during the platform→sleep app-of-apps split (final `tofu apply` never ran), leaving the
      sleep-ingester CronJob orphaned. Re-applied `helm_release.argocd_apps`; `sleep` +
      `sleep-tracking` + `sleep-ingester` are Synced/Healthy again.

The original bring-up items (kept for history):

- [ ] **Run the bootstrap** — `scripts/github-runner-bootstrap.sh` (runbook:
      [`docs/github-runner-bootstrap.md`](github-runner-bootstrap.md)). Scripted: creates the
      `teststuffstash` GitHub App (Organization → Self-hosted runners: R/W, + Metadata: Read) via the
      App-manifest REST flow, discovers the install id, and pushes `GHARC_APP_ID`/`GHARC_INSTALL_ID`/
      `GHARC_PRIVATE_KEY` + `SLEEP_GHCR_PULL_TOKEN` (read:packages PAT) into Infisical (copies to
      `~/.claude/homelab-github-arc/`). Only manual clicks: App "Create" + "Install", and minting the
      ghcr PAT.
- [ ] **Sync ARC** — `argocd/platform/{arc-controller,github-runner-secrets,arc-runners}.yaml` +
      `argocd/resources/github-runner/`. **Confirm the ARC chart version** (`0.12.1` placeholder in
      both `arc-controller.yaml` and `arc-runners.yaml` — they MUST match) against
      github.com/actions/actions-runner-controller/releases. Verify the `homelab-ephemeral` scale set
      shows up in the org runner settings and a `workflow_dispatch` spawns a pod on a wk-metal node.
- [ ] **ghcr cutover for sleep-ingester** — registry flipped to `ghcr.io/teststuffstash/sleep-ingester`
      (`argocd/sleep/values/sleep-ingester.yaml` + the repo's `infra/externalsecret.yaml` now build a
      ghcr dockerconfigjson). First ghcr build must publish before bumping the `tag`; until then the
      old Forgejo image keeps the CronJob running. Verify the CronJob pod pulls from ghcr (no
      `ImagePullBackOff`). The old `SLEEP_FORGEJO_REGISTRY_TOKEN` Infisical key can be retired after.
- [ ] **sleep-tracking has 4 red tests** — working CI immediately surfaced pre-existing failures
      (snore `nights/` prefix change not reflected in fixtures; coverage 84.41% < 85% gate). Fix the
      fixtures/coverage or adjust the gate — they were invisible while CI ran on a dead `main` branch.
- [ ] **SSH clone** — `service.ssh` is ClusterIP (HTTP clone only for now). Expose if wanted.
- [ ] **Gogs on the edge** — separate, lighter Git service for the grandma tablet+minipc (ROADMAP).

## Monitoring / Longhorn

- [x] **CloudNativePG monitoring** (2026-06-24) — added a `cnpg` PrometheusRule group + the
      `CloudNativePG` Grafana dashboard (`tofu/dashboards/cnpg.json`) and enabled
      `spec.monitoring.enablePodMonitor` on both Clusters (forgejo-pg, infisical-pg). Prompted by
      **forgejo-pg-2 sitting as a broken replica for 2.5 days unnoticed**: a failover during the
      2026-06-19 metal flap left it on a divergent timeline, so it crash-looped on
      `pg_rewind: could not find common ancestor of the source and target cluster's timelines`
      (readiness 500). **Recovery recipe** (no data loss — primary is intact): delete the replica's
      PVC + pod so CNPG re-clones it via `pg_basebackup` —
      `kubectl -n <ns> delete pvc <cluster>-N; kubectl -n <ns> delete pod <cluster>-N`
      (CNPG re-creates as the next instance number, e.g. `-2` → `-3`). If a replica re-diverges,
      suspect the node it lands on (forgejo-pg is pinned to wk-01/wk-02; watch wk-02).

- [ ] **Longhorn runs on the ephemeral laptops** — `KubeDaemonSetMisScheduled` ×2 + a stale
      instance-manager PDB (`KubePdbNotEnoughHealthyPods`) fire because Longhorn schedules its
      manager/engine-image/instance-manager onto wk-metal-01/02 (compute-only, no storage). Decide:
      scope Longhorn off the ephemeral tier (taint-toleration / system-managed-components node
      selector) vs. silence those two default rules.
- [ ] **Longhorn dashboard "Alerts" panel** stays empty by design — it's a Grafana unified-alerting
      `alertlist`, but we alert via Prometheus→Alertmanager (where the Longhorn alerts *do* fire).
      Optional: repoint that one panel to a Prometheus `ALERTS{alertname=~"Longhorn.*"}` query
      (small dashboard-JSON tweak, lost on re-fetch).

## Hardware / nodes

- [ ] **thinkcentre BIOS → disk-first** — it's PXE-first, so every boot pays a PXE timeout before
      falling to disk. Setting BIOS disk-first gives fast boots (and a persistent matchbox flag
      would then be safe again).
- [ ] **Watch thinkcentre + wk-metal-02** — thinkcentre had one brief 1Gbps link blip after the
      cable fix (2026-06-11); wk-metal-02 had one unexplained reboot. If either recurs: chase the
      cable/switch-port (thinkcentre) or battery/power (wk-metal-02, on smart-plug laptop4).
- [ ] **qemu-guest-agent on metal nodes** — harmless `ext-qemu-guest-agent` "Waiting" service on
      bare metal (install image shared with the VMs). Keeps Talos's stage at `booting`; dropping it
      needs a metal-specific schematic — not worth a fleet reinstall.

## Ops / housekeeping

- [ ] **`kubernetes_deployment.ha` tofu drift** — `tofu plan` shows Home Assistant wanting an
      in-place update that's been target-skipped repeatedly. Investigate what drifted (a manual live
      change?) and reconcile into git or accept it.
- [ ] **HA `refresh_token` is dead** — `~/.claude/homelab-ha/refresh_token` returns `invalid_grant`;
      currently falling back to `prometheus_llat`. Regenerate the refresh/long-lived token.
- [ ] **GitHub PAT in plaintext** — the `origin` URL embeds the PAT (visible in `git remote -v`).
      Move it to a git credential helper.
- [ ] **Talos 1.14 upgrade prep** — before upgrading, apply the `VolumeConfig secure:false` patch or
      `noexec` on `/var` breaks Longhorn v1 (already documented in `tofu/longhorn.tf`).

See also `ROADMAP.md` → "Backlog / parked features" (bare-metal node suspend/resume "autoscaler").
