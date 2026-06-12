# Follow-ups & in-progress

Running list of loose ends and deferred work — the stuff intentionally not finished yet. Most
features land complete + committed; this captures the "come back to it" items so they don't get
lost. Bigger parked features live in `ROADMAP.md` → "Backlog".

_Last updated: 2026-06-11._

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
      Stand up Postgres (CloudNativePG is the clean k8s-native operator) and point Forgejo at it
      (`gitea.config.database.*`); migrate the SQLite data or start fresh.
- [ ] **GitHub → Forgejo mirroring** — Forgejo pull-mirrors so a local copy of the GitHub repos
      survives GitHub being down (the ArgoCD-resilience goal — don't be hostage to GitHub uptime).
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
