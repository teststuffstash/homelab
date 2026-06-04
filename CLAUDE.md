# CLAUDE.md

Guidance for Claude Code (claude.ai/code) working in this repo.

## What this is

Infrastructure-as-code for a home network, built **boot-from-git**: every box is meant to be
recreatable from this repo, the only non-code thing is data (→ S3, bucket-id in git). No click-ops.
There's no build step or test suite — changes are applied directly to live machines via OpenTofu,
Ansible, and Talos. See `CONTEXT.md` for the guiding principles, `ARCHITECTURE.md` for the shape,
`ROADMAP.md` for what/when, and **`docs/runbook.md` for the operational recipes** (the most useful
day-to-day reference).

## Environment

Running inside a Docker jail — see `/workspace/CLAUDE.md` for container setup and permissions.
**All project CLI tooling is Devbox/Nix, not apt** (`devbox.json` at the repo root, shared host
`/nix`). Tools are NOT on the bare `$PATH` — reach them through devbox:

```bash
devbox run -- kubectl --kubeconfig tofu/kubeconfig get nodes
devbox run -- tofu -chdir=tofu plan
devbox run nodes        # convenience: kubectl get nodes -o wide
devbox run k9s          # cluster TUI on tofu/kubeconfig
```

Toolchain: opentofu, kubectl, talosctl, kubernetes-helm, cilium-cli, k9s, ansible, sops, age, jq,
yq, python3, **dig/host (bind), nmap, curl, nc/ncat, cloudflared**. `nix` commands need
`export NIX_CONFIG="experimental-features = nix-command flakes"`. `devbox run` executes from the
repo root and runs scripts under **dash** — keep them simple, use absolute paths / `tofu -chdir=`,
avoid `bash -c '<multiline>'` (it mangles).

## Current state (2026-06)

A Talos Linux Kubernetes cluster, hybrid Proxmox VMs + bare-metal, with OPNsense managed as code.

| Host | IP | Role |
|---|---|---|
| OPNsense ("Big Data", HP desktop) | 192.168.2.1 | Router/FW + DHCP (dnsmasq) + DNS (Unbound) + FRR/BGP + HAProxy + ACME |
| Proxmox `pve` (X99/Xeon, 64GB) | 192.168.2.3 | Hypervisor for the Talos VMs + Matchbox LXC |
| Matchbox LXC (CTID 210) | 192.168.2.30 | PXE provisioning (proxy-DHCP + TFTP + Matchbox) |
| `cp-01` (VM) | 192.168.2.51 | k8s control plane |
| `wk-01` / `wk-02` (VMs) | .61 / .62 | workers (wk-02 in Longhorn) |
| `thinkcentre` (metal, USB) | 192.168.2.53 | worker + Longhorn (+ 2×Optane fast tier) |
| `hp-01` (metal, PXE) | 192.168.2.54 | worker + Longhorn (WoL-capable) |
| `wk-metal-01` (ThinkPad X240, PXE) | 192.168.2.182 | worker, ephemeral/compute tier (tainted) |
| `wk-metal-02` (ThinkPad X250, PXE) | 192.168.2.183 | worker, ephemeral/compute tier (tainted) |
| Droplet (ESP32) | 192.168.2.245 | ESPHome plant-irrigation node |
| pop-os | 192.168.2.10 / .57 | the Docker host running this jail |

Cluster: **Talos v1.13.2 / Kubernetes v1.36.1**, **Cilium 1.19.1** CNI (kube-proxy-free).
The **Lenovo T61 (.2) is dead/retired** — it used to run netboot.xyz + the UniFi controller, both
since migrated. Anything in old docs about the T61 serving things is stale.

### Service exposure

In-cluster Services get **LoadBalancer VIPs from `192.168.40.0/24`** via Cilium BGP peering
OPNsense FRR (cluster ASN 64513 ↔ OPNsense 64512). Only Services labelled `bgp=advertise` are
advertised. L2 auto-discovery does NOT cross this L3/BGP boundary.

| Service | Cluster VIP | HTTPS name (OPNsense HAProxy → LAN VIP) |
|---|---|---|
| Home Assistant | 192.168.40.10:8123 | `homeassistant.teststuff.net` (.5) |
| Grafana | 192.168.40.11 | `grafana.teststuff.net` (.6) |
| UniFi Network App | 192.168.40.12 (8443/8080/3478/10001) | `ubiquiti.teststuff.net` → .40.12 (Unbound) |
| Prometheus | 192.168.40.13:9090 | `prometheus.teststuff.net` (.7) |
| Alertmanager | 192.168.40.14:9093 | `alertmanager.teststuff.net` (.8) |

OPNsense web UI: `https://opnsense.teststuff.net`. Storage is **Longhorn** (default StorageClass,
replicated) + a `longhorn-fast` node-local tier on the ThinkCentre's Optane.

## Repo layout

- `tofu/` — main cluster root (Talos VMs, Cilium + BGP, Longhorn, Home Assistant, UniFi,
  monitoring, bare-metal nodes `metal.tf`, image factory). State is local + gitignored.
  Run via `devbox run -- tofu -chdir=tofu <cmd>`. **Always `plan` and review before `apply`.**
- `tofu/provisioning/` — Matchbox LXC + PXE content (separate root/state).
- `ansible/` — OPNsense as code: `opnsense-bgp.yml`, `opnsense-acme.yml`, `opnsense-haproxy.yml`,
  `opnsense-unbound-hosts.yml`, `opnsense/dnsmasq-dhcp.py`, and `matchbox*.yml`. Run OPNsense
  playbooks via **`bash scripts/opnsense-playbook.sh ansible/opnsense-<play>.yml`** (handles the
  httpx interpreter + creds — see `docs/runbook.md`).
- `esphome/` — ESPHome dashboard + device configs (`config/droplettest.yaml`); flash with
  `devbox run flash-droplet`.
- `homeassistant/` — Home Assistant config kept in git (applied imperatively; see runbook).
- `scripts/` — `talos-usb.sh`, `opnsense-playbook.sh`, `longhorn-register-optane.sh`.
- `rocky/`, `ubuntu/`, `cloud-init.yml`, `netboot.xyz/`, `pfsense/` — legacy/full-OS provisioning,
  mostly superseded by the Talos/Matchbox path.

## Secrets

Out-of-repo, in the jail under `~/.claude/`: `homelab-opnsense/{key,secret}` (OPNsense API),
`homelab-pve-ssh/` (Proxmox token + SSH seed key), `homelab-matchbox/` (gRPC client certs),
`homelab-ha/` (Home Assistant tokens + Grafana pw), `homelab-droplet/`. Tofu state, `*.tfvars`,
`kubeconfig`, `talosconfig` are gitignored. The repo is **slated to go public eventually** — keep
secrets out of git (SOPS+age for anything that must live in git); see `PUBLISH-CHECKLIST.md`.

## Safety

- `plan`/dry-run and review before any `apply`; this hits live machines.
- **Never `talosctl upgrade` a Proxmox *nocloud* VM** — it loses its static IP/hostname and rejoins
  as a ghost. Bake extensions into the image (`image.tf`) and recreate. Metal nodes upgrade fine.
- Never iterate destructive OPNsense firmware endpoints (`/reboot`, `/poweroff`) to "discover" them
  — they execute.
- Don't claim "done" without an isolated end-state check.

More detail and the full set of operational recipes live in **`docs/runbook.md`**.
