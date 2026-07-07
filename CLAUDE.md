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
yq, python3, openssl, awscli2, **dig/host (bind), nmap, curl, nc/ncat, cloudflared**. `nix` commands need
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
| `ci-runner-01` (VM) | 192.168.2.55 | GitHub Actions runner VM — Docker/binfmt builds (ADR-082) |
| Droplet (ESP32) | 192.168.2.245 | ESPHome plant-irrigation node |
| pop-os | 192.168.2.10 / .57 | the Docker host running this jail |

Cluster: **Talos v1.13.2 / Kubernetes v1.36.1**, **Cilium 1.19.1** CNI (kube-proxy-free).

### Service exposure

> **The canonical catalog of platform services (status + endpoints + how to consume) is
> [`SERVICES.md`](SERVICES.md).** Apps in other repos discover services by grepping it — keep it
> current when you deploy/remove a service. The table below is the BGP/HAProxy mechanics.

In-cluster Services get **LoadBalancer VIPs from `192.168.40.0/24`** via Cilium BGP peering
OPNsense FRR (cluster ASN 64513 ↔ OPNsense 64512). Only Services labelled `bgp=advertise` are
advertised. L2 auto-discovery does NOT cross this L3/BGP boundary. LAN HTTPS names
(`<name>.teststuff.net`) ride OPNsense HAProxy IP-alias VIPs (`.2.5`–`.2.9`) + Unbound overrides —
recipe in `docs/runbook.md`. **The per-service VIP/hostname assignments live in `SERVICES.md`**
(don't duplicate them here).

OPNsense web UI: `https://opnsense.teststuff.net`. Storage is **Longhorn** (default StorageClass,
replicated) + a `longhorn-fast` node-local tier on the ThinkCentre's Optane.

**Remote access (live):** Home Assistant is reachable from anywhere at **`https://ha.teststuff.net`**
via a **Cloudflare Tunnel** (`cloudflared` in-cluster) gated by **client-certificate mTLS** — see
`tofu/cloudflare/` + `docs/cloudflare.md`. The `teststuff.net` zone now lives on **Cloudflare**
(moved off Route53), so OPNsense **ACME is DNS-01 via Cloudflare** (`ansible/opnsense-acme.yml`), not
Route53. LAN HTTPS names above stay on the local HAProxy path; only `ha.teststuff.net` is public.

## Repo layout

- `tofu/` — main cluster root (Talos VMs, Cilium + BGP, Longhorn, Home Assistant, UniFi,
  monitoring, bare-metal nodes `metal.tf`, image factory). State is local + gitignored.
  Run via `devbox run -- tofu -chdir=tofu <cmd>`. **Always `plan` and review before `apply`.**
- `tofu/provisioning/` — Matchbox LXC + PXE content (separate root/state).
- `tofu/cloudflare/` — remote access (tunnel, `cloudflared` Deployment, DNS, mTLS cert + WAF rule;
  separate root/state). `tofu/cloudflare-token/` mints the scoped CF tokens (run once with an admin
  token, outside the jail). See `docs/cloudflare.md`.
- `ansible/` — OPNsense + Matchbox as code, **thin playbooks → `roles/`** with config in
  `group_vars/` (`opnsense-bgp`, `-acme`, `-haproxy`, `-unbound`; `matchbox*`), plus
  `opnsense/dnsmasq-dhcp.py` (LAN DHCP). Run OPNsense playbooks via
  **`bash scripts/opnsense-playbook.sh ansible/opnsense-<play>.yml`** (handles the httpx
  interpreter + creds + `ANSIBLE_CONFIG` — see `ansible/readme.md`, `docs/runbook.md`).
- `esphome/` — ESPHome device configs (`config/office-plants-irrigation.yaml`); flash with
  `devbox run flash-irrigation` (logs: `devbox run irrigation-logs`).
- `homeassistant/` — Home Assistant config kept in git (applied imperatively; see runbook).
- `scripts/` — wrappers + one-shots: `tf.sh` / `keepass-{env,init}.sh` (secret vars for tofu),
  `opnsense-playbook.sh`, `infisical-{secret,harden}.sh`,
  `github-{runner,agents,reviewer,merge,deploy}-*bootstrap.sh` + `gh-app-runner-token.sh` (GitHub Apps),
  `github-exporter-pat-bootstrap.sh` (PAT for the GitHub→Prometheus poller),
  `new-agent-repo.sh` (scaffold a repo into tofu/github), `garage-s3.sh`, `talos-usb.sh`,
  `longhorn-register-optane.sh`, `make-client-p12.sh` (phone mTLS cert, pinned openssl),
  `coordinator-logs.sh`/`render-transcript.py`, `follow-ups-lint.sh`, `aws-*.sh` (one-shot audit/cleanup).
- `machines/` — machine inventory (`machines.yaml`) + table generator (`generate.py` → `README.md`).
- `docs/` — operations & design docs + per-service docs (entrypoint: `docs/office-plants/`);
  decision history in `docs/adr.md`.

## Secrets

Out-of-repo, in the jail under `~/.claude/`: `homelab-opnsense/{key,secret}` (OPNsense API),
`homelab-pve-ssh/` (Proxmox token + SSH seed key), `homelab-matchbox/` (gRPC client certs),
`homelab-ha/` (Home Assistant tokens + Grafana pw), `homelab-droplet/`, `cloudflare/`
(read/write/acme tokens + the phone `.p12`), `homelab-aws/` (scoped read-only audit key). Tofu state, `*.tfvars`,
`kubeconfig`, `talosconfig` are gitignored. The repo is **public** — keep secrets out of git
(values live in KeePass/Infisical, see `docs/secrets.md`; SOPS is NOT used, ADR-062).

**In-cluster agent secrets** (k8s Secrets, not `~/.claude/` files): per-project `<project>-openrouter`
(operator-minted OpenRouter key) + the worker `agent-git-token` (per-repo, ~1h, from the `homelab-agents`
GitHub App). The **coordinator** (`agents/coordinator/`) adds two in ns `agent-coordinator`:
`coordinator-claude` (`CLAUDE_CODE_OAUTH_TOKEN` — a ~1y `claude setup-token`, the operator's Pro/Max
subscription) and `coordinator-git` (`GH_TOKEN` — `issues:write`+`pull_requests:write`+`contents` across
the agent repos; prefer minting from the `homelab-agents` App over a new PAT — see
`agents/coordinator/README.md` §Git token). The coordinator **image** CI needs no token (ghcr push via
the built-in `GITHUB_TOKEN`). Imperative for now; fold into Infisical/ESO later (FU-001).

## Follow-ups (FU-NNN)

Loose ends and deferred work are tracked **only** in `docs/follow-ups.md`, one stable id per item
(`FU-NNN`, never reused — conventions at the top of that file). The rules that keep it consistent:

- **New deferred work / discovered loose end** → add an `FU-NNN` item there first. Never leave a
  free-floating `TODO` in code or docs — write the comment as `FU-NNN: <context>` instead.
- **Resolved something?** `git grep FU-NNN` and delete the item **and every reference** in the same
  commit as the fix. `devbox run follow-ups-lint` catches dangling references.
- Roadmap-scale parked *features* go to `ROADMAP.md` → Backlog, not here.

## Safety

- `plan`/dry-run and review before any `apply`; this hits live machines.
- **Never `talosctl upgrade` a Proxmox *nocloud* VM** — it loses its static IP/hostname and rejoins
  as a ghost. Bake extensions into the image (`image.tf`) and recreate. Metal nodes upgrade fine.
- Never iterate destructive OPNsense firmware endpoints (`/reboot`, `/poweroff`) to "discover" them
  — they execute.
- Don't claim "done" without an isolated end-state check.

More detail and the full set of operational recipes live in **`docs/runbook.md`**.
