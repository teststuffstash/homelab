# Architecture — the homelab in planes

How this homelab is *shaped*, documented the way the
[Platform Engineering Org platform-tooling landscape](https://platformengineering.org/platform-tooling)
does it: not as a vertical stack (hardware → OS → k8s → apps) but as **horizontal planes** —
domains that scale sideways and talk to each other through APIs.

Companion docs: **`ROADMAP.md`** = what/when, **`CONTEXT.md`** = why/how-I-think,
**`docs/adr.md`** = the decisions (what was considered + chosen), this file = *how it's shaped*.

**How to read it.** Three planes flow left→right (the path from me to a running workload);
two planes are cross-cutting bands over all of them:

```mermaid
flowchart LR
    subgraph OBS["Observability Plane · cross-cutting"]
        O["Prometheus · Grafana · Loki · alerts → Home Assistant · Civo cost"]
    end
    subgraph DEV["1 · Developer Control Plane"]
        D["Git · OpenTofu · Ansible · kubectl · talosctl · k9s · Helm"]
    end
    subgraph DEL["2 · Integration & Delivery Plane"]
        I["GitHub · Actions · GHCR · ArgoCD/Flux · Talos + k8s control plane"]
    end
    subgraph RES["3 · Resource Plane"]
        R["Proxmox · bare-metal · Talos VMs · Cilium · OPNsense · Cloudflare · S3 · Civo"]
    end
    subgraph SEC["Security Plane · cross-cutting"]
        S["SOPS+age · OPNsense FW · Cilium NetworkPolicy · WireGuard · AMT · RBAC"]
    end
    OBS -.spans.-> DEV
    DEV --> DEL --> RES
    RES -.audited by.-> SEC
```

_Fig. 0: Five planes — three in a left-to-right delivery flow, two spanning everything._

Status key: ✅ running · 🔜 planned (see `ROADMAP.md`) · ⬜ gap / not yet.

---

## 1 · Developer Control Plane

```mermaid
flowchart TB
    subgraph IF["Interface"]
        A["kubectl · talosctl · k9s · Devbox shell"]
    end
    subgraph IAC["IaC / GitOps authoring"]
        B["Git · OpenTofu (bpg/proxmox, talos, matchbox) · Ansible (O-X-L OPNsense) · Helm"]
    end
    subgraph PORTAL["Portal"]
        C["large-button tablet UI (end-user, for the assistive-tech product)"]
    end
```

_Fig. 1: Developer Control Plane — where I author the platform from git, never by clicking._

- ✅ Git/GitHub, OpenTofu, kubectl/talosctl/k9s/Devbox/Helm (daily tools).
- 🔜 ArgoCD/Flux as the GitOps front (lives mostly in plane 2).
- ⬜ No internal developer portal (Backstage) — out of scope for a solo lab; the only
  "portal" that matters is the **end-user tablet UI** for the elderly-care product.

## 2 · Integration & Delivery Plane

```mermaid
flowchart LR
    VC["Version Control<br/>GitHub"] --> CI["CI<br/>GitHub Actions"]
    CI --> REG["Registry<br/>GHCR / Docker Hub"]
    REG --> CD["Orchestration & CD<br/>OpenTofu · ArgoCD/Flux"]
    CD --> CCP["Cluster Control Plane<br/>Talos + Kubernetes"]
```

_Fig. 2: Integration & Delivery Plane — the path from a commit to a reconciled cluster._

- ✅ GitHub (`teststuffstash`), GHCR/Docker Hub as image sources.
- ✅ OpenTofu provisioning (cluster live), Talos + Kubernetes control plane (v1.13.2 / v1.36.1).
- 🔜 ArgoCD/Flux GitOps front.
- ⬜ CI (GitHub Actions) not wired yet; no internal image registry (use upstream for now).

## 3 · Resource Plane

```mermaid
flowchart TB
    subgraph COMPUTE["Compute"]
        C1["Proxmox (X99) · bare-metal fleet · Talos VMs · Civo (cloud burst)"]
        C2["Provisioning: Matchbox (MAC table) · WoL / AMT / smart-plug power"]
    end
    subgraph DATA["Data"]
        D1["local-lvm · Longhorn · S3 / MinIO (backups, bucket-in-git) · Postgres/MariaDB"]
    end
    subgraph NET["Networking"]
        N1["OPNsense (DHCP/DNS/FW/FRR) · Cilium CNI + BGP · Cloudflare Tunnel · CARP"]
    end
    subgraph SVC["Services"]
        S1["Home Assistant + add-ons (Mosquitto, Zigbee2MQTT, ESPHome) · public apps · edge appliances"]
    end
```

_Fig. 3: Resource Plane — where YAMLs finally meet hardware (and there's no IPMI)._

- ✅ Proxmox host, OPNsense (DHCP/DNS/FW/FRR as code), ESPHome + the `droplet` node.
- ✅ Talos VMs **and** bare-metal nodes, Matchbox PXE provisioning, Cilium + BGP LoadBalancer,
  Longhorn storage, Home Assistant + UniFi controller in-cluster.
- ✅ Cloudflare Tunnel (Home Assistant remote access via `ha.teststuff.net` + mTLS, `docs/cloudflare.md`);
  `teststuff.net` DNS now on Cloudflare.
- 🔜 S3 backups, Civo burst.
- ⬜ CARP HA pair (needs ≥2 hosts), network Zigbee coordinator (to buy).

## 4 · Observability Plane _(cross-cutting)_

```mermaid
flowchart LR
    AG["Agents collect<br/>node/pod metrics · logs"] --> BR["Central brain<br/>Prometheus · Grafana · Loki"]
    BR --> AL["Act<br/>alerts → Home Assistant / push"]
    BR --> FIN["FinOps<br/>Civo scale-to-zero cost control"]
```

_Fig. 4: Observability Plane — small agents collect, one central brain visualizes and alerts._

- ✅ Prometheus + Grafana + Alertmanager in-cluster (`tofu/monitoring.tf`), exposed at
  `grafana`/`prometheus`/`alertmanager.teststuff.net`.
- 🔜 Log aggregation (Loki), alerting routed to Home Assistant, Civo cost/FinOps.

## 5 · Security Plane _(cross-cutting)_

```mermaid
flowchart TB
    subgraph SECRETS["Secrets"]
        K["SOPS + age (encrypted in git) · Proxmox/AMT creds out of git"]
    end
    subgraph NETSEC["Network Security"]
        F["OPNsense firewall · Cilium NetworkPolicy · WireGuard / VPN"]
    end
    subgraph IAM["IAM / Identity"]
        I["k8s RBAC · Cloudflare mTLS (client certs) + scoped API tokens · OPNsense users"]
    end
    subgraph POSTURE["Posture / Policy"]
        P["AMT hardening (LAN-only) · image/policy scanning"]
    end
```

_Fig. 5: Security Plane — secrets live in git but encrypted; the edge stays locked, the BMC patched._

- ✅ Cloudflare edge security at the public edge: client-certificate **mTLS** (WAF-enforced, not
  Enterprise Access) on `ha.teststuff.net`, plus **scoped per-job Cloudflare API tokens** as code
  (`tofu/cloudflare-token/`). AWS access is IAM Identity Center SSO (no static admin keys).
- 🔜 SOPS+age (for anything that must live in git), Cilium NetworkPolicy,
  AMT hardening, OPNsense firewall as code.
- ⬜ Policy engine (Kyverno/Gatekeeper) and a real identity layer — deferred.

---

> The end-state "boot from git" goal means every box in these planes is recreatable from this
> repo; the only thing that isn't code is data, which backs up to S3 with the bucket ID in git.
> See `CONTEXT.md` principle #1.
