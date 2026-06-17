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
- [ ] **GitHub → Forgejo mirroring** — Forgejo pull-mirrors so a local copy of the GitHub repos
      survives GitHub being down. This is the prerequisite for the **ArgoCD → Forgejo cutover** (see the
      GitOps & secrets section above) — the ArgoCD-resilience goal: don't be hostage to GitHub uptime.
- [ ] **Forgejo Actions runner** (`act_runner`) — the vendor-neutral CI seam: workflows just call
      `devbox run <task>` so build/test logic stays in the repo, not the forge's YAML (cf. the
      vfarcic example). The same logic then runs under GitHub Actions *and* Forgejo Actions. Pin it
      to the tainted ephemeral laptop tier (CI noise/privilege off the service nodes). This is also
      **Phase 1** of the supply-chain plan — see [`slsa.md`](slsa.md) (act_runner + cosign + SBOM =
      Build L2; throwaway test clusters via `k3d`/`vcluster` in `devbox run test`, not DinD/kubedock).
- [ ] **SSH clone** — `service.ssh` is ClusterIP (HTTP clone only for now). Expose if wanted.
- [ ] **Gogs on the edge** — separate, lighter Git service for the grandma tablet+minipc (ROADMAP).

## Monitoring / Longhorn

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
