# homelab

Infrastructure-as-code for a home network, built **boot-from-git**: every box is recreatable from
this repo (data is the only exception → S3, bucket-id in git). A Talos Linux Kubernetes cluster
(hybrid Proxmox VMs + bare-metal), with OPNsense managed as code, provisioned via DIY netboot.

- **`CONTEXT.md`** — why / the principles behind decisions.
- **`ARCHITECTURE.md`** — how it's shaped (planes).
- **`ROADMAP.md`** — what / when.
- **`docs/runbook.md`** — operational recipes (start here to *do* things).
- **`docs/provisioning.md`** — onboard a bare-metal node. **`docs/cloudflare.md`** — remote-access design.
- **`docs/adr.md`** — architecture decision record (what was considered, what was chosen, and why).
- **`docs/`** — service & ops docs index; the [office-plants service](docs/office-plants/README.md) is
  the original reason this lab exists.
- **`CLAUDE.md`** — orientation for the AI agent that does most of the work here.

## Topology

<!-- BEGIN GENERATED hosts — do not edit; edit machines/machines.yaml and run `devbox run -- python3 machines/generate.py` -->
| Host | IP | Role |
|---|---|---|
| OPNsense ("Big Data", HP desktop) | 192.168.2.1 | Router/FW + DHCP (dnsmasq) + DNS (Unbound) + FRR/BGP + HAProxy + ACME |
| Proxmox `pve` (X99/Xeon, 64GB) | 192.168.2.3 | Hypervisor for the Talos VMs + Matchbox LXC |
| Matchbox LXC (CTID 210) | 192.168.2.30 | PXE provisioning (proxy-DHCP + TFTP + Matchbox) |
| `cp-01` (VM) | 192.168.2.51 | k8s control plane |
| `wk-01` (VM) | 192.168.2.61 | k8s worker + Longhorn |
| `wk-02` (VM) | 192.168.2.62 | k8s worker + Longhorn (bulk tier) |
| `thinkcentre` (metal, PXE) | 192.168.2.53 | k8s worker + Longhorn (+ 2×Optane fast tier) |
| `hp-01` (metal, PXE) | 192.168.2.54 | k8s worker + Longhorn (WoL-capable) |
| `wk-metal-01` (ThinkPad X240, PXE) | 192.168.2.182 | k8s worker, ephemeral/compute tier (tainted; kata node, 8GB) + Longhorn bulk tier |
| `wk-metal-02` (ThinkPad X250, PXE) | 192.168.2.183 | k8s worker, ephemeral/compute tier (tainted; kata node, 8GB) |
| `wk-metal-03` (laptop i5-6200U, PXE) | 192.168.2.184 | k8s worker, ephemeral/compute tier (tainted; kata node) |
| `wk-metal-04` (desktop i5-3570K 16GB, PXE) | 192.168.2.186 | k8s worker, ephemeral/compute tier (tainted; kata node, no AVX2) + Longhorn bulk tier |
| `ci-runner-01` (VM) | 192.168.2.55 | GitHub Actions runner VM — Docker/binfmt builds (ADR-082) |
| Droplet (ESP32) | 192.168.2.245 | ESPHome plant-irrigation node |
| pop-os | 192.168.2.10 / .57 | the Docker host running this jail |
<!-- END GENERATED hosts -->

<!-- BEGIN GENERATED versions — do not edit; edit machines/machines.yaml and run `devbox run -- python3 machines/generate.py` -->
Cluster: **Talos v1.13.2 / Kubernetes v1.36.1**, **Cilium 1.19.1** CNI (kube-proxy-free).
<!-- END GENERATED versions -->

(Host table + version line above are generated from [`machines/machines.yaml`](machines/machines.yaml)
— see [`machines/`](machines/README.md).)

Storage is **Longhorn**. In-cluster Services get LoadBalancer VIPs from `192.168.40.0/24` (Cilium
BGP ↔ OPNsense FRR) and a trusted HTTPS name via OPNsense HAProxy. **The service catalog — what's
running, every endpoint, how to consume it — is [`SERVICES.md`](SERVICES.md)** (Home Assistant,
Grafana/Prometheus, UniFi, Garage S3, Forgejo, ArgoCD, Infisical/ESO, Postgres/CNPG, CI runners, …).

**Remote access:** Home Assistant is reachable from anywhere at `https://ha.teststuff.net` via a
**Cloudflare Tunnel** + client-certificate **mTLS** (the `teststuff.net` zone now lives on Cloudflare;
LAN names stay on local HAProxy). See [`docs/cloudflare.md`](docs/cloudflare.md).

## Use

```bash
devbox shell                                   # toolchain from devbox.json (Nix)
devbox run -- tofu -chdir=tofu plan            # review before apply — this hits live machines
devbox run nodes                               # kubectl get nodes -o wide
bash scripts/opnsense-playbook.sh ansible/opnsense-haproxy.yml   # OPNsense as code
```

State, `*.tfvars`, `kubeconfig`/`talosconfig`, and secrets are gitignored / kept out of the repo
(secret values live in a KeePass Tier-0 wallet + self-hosted Infisical/ESO — see
[`docs/secrets.md`](docs/secrets.md)). This is a real, running homelab published openly —
infrastructure code shouldn't need security-through-obscurity.

## License

[AGPL-3.0-or-later](LICENSE) — Copyright (C) 2026 Rasmus Soot. Build on it; keep derivatives open.
