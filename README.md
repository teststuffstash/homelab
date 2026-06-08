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

| Host | IP | Role |
|---|---|---|
| OPNsense ("Big Data") | 192.168.2.1 | Router/FW, DHCP (dnsmasq), DNS (Unbound), FRR/BGP, HAProxy, ACME |
| Proxmox `pve` | 192.168.2.3 | Hypervisor (Talos VMs + Matchbox LXC) |
| Matchbox LXC | 192.168.2.30 | PXE provisioning (proxy-DHCP + TFTP + Matchbox) |
| `cp-01` / `wk-01` / `wk-02` | .51 / .61 / .62 | Talos cluster VMs (control plane + workers) |
| `thinkcentre` / `hp-01` | .53 / .54 | bare-metal workers (+ Longhorn) |
| `wk-metal-01` / `wk-metal-02` | .182 / .183 | bare-metal workers (ThinkPad X240/X250, ephemeral tier) |
| Droplet (ESP32) | 192.168.2.245 | ESPHome plant-irrigation node |

Cluster: **Talos v1.13.2 / Kubernetes v1.36.1**, **Cilium 1.19.1** (kube-proxy-free), **Longhorn**
storage. In-cluster Services get LoadBalancer VIPs from `192.168.40.0/24` (Cilium BGP ↔ OPNsense
FRR) and a trusted HTTPS name via OPNsense HAProxy:

| Service | VIP | HTTPS |
|---|---|---|
| Home Assistant | 192.168.40.10 | `homeassistant.teststuff.net` (LAN) · `ha.teststuff.net` (remote) |
| Grafana / Prometheus / Alertmanager | .11 / .13 / .14 | `grafana` / `prometheus` / `alertmanager.teststuff.net` |
| UniFi Network Application | 192.168.40.12 | `ubiquiti.teststuff.net` |

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

State, `*.tfvars`, `kubeconfig`/`talosconfig`, and secrets are gitignored / kept out of the repo.
This repo is **slated to go public** — see `PUBLISH-CHECKLIST.md` before pushing it anywhere public.
