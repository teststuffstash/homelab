# Architecture Decision Record (ADR)

A single-page log of the **significant decisions** behind this homelab: what was considered, what
was chosen, and why. Companion to [`CONTEXT.md`](../CONTEXT.md) (the decision *lens*),
[`ROADMAP.md`](../ROADMAP.md) (the *plan*) and [`ARCHITECTURE.md`](../ARCHITECTURE.md) (the *shape*).

Format: lightweight ADRs (one block each). **Status:** Accepted / Superseded / Open. Dates are when
the call was made; most trace to the 2026-05 planning and the 2026-06 build. Decisions are weighed
against the `CONTEXT.md` principles — reproducible-from-git, deterministic diffs, local-first,
open-source/replaceable, budget-conscious, public-by-default.

> Newest decisions are at the bottom of each area. Where a decision was **reversed mid-flight**, the
> reversal is recorded too (it's part of the record).

---

## Platform & IaC

### ADR-001 — Boot-from-git as the governing constraint
**Status:** Accepted (2026-05-24). **Decision:** every box is recreatable from this repo; the only
non-code thing is data (→ S3, bucket-id in git). No click-ops; web UIs are for viewing.
**Considered:** pragmatic "configure-by-hand, document-after" vs strict IaC.
**Why:** principle #1 — git is the single source of truth; hardware/cloud-agnostic recovery (must be
able to `tofu apply` onto AWS EC2 if hardware dies). **Consequences:** anything not expressible as
code gets wrapped (API/IaC) or logged as a temporary exception; constrains every choice below.

### ADR-002 — OpenTofu, not Terraform
**Status:** Accepted (2026-05-24). **Decision:** OpenTofu for all IaC.
**Considered:** Terraform (BSL license) vs OpenTofu (MPL fork).
**Why:** principle #5 — open-source & replaceable, no lock-in. **Consequences:** providers
`bpg/proxmox`, `siderolabs/talos`, `poseidon/matchbox`, `cloudflare/cloudflare`, `hashicorp/{kubernetes,helm,tls}`.

### ADR-003 — GitOps (ArgoCD/Flux) deferred; `tofu apply` for now
**Status:** Open (2026-05-24). **Decision:** drive the cluster with `tofu apply` (+ a Helm provider)
today; add a GitOps controller later. **Considered:** ArgoCD vs Flux vs tofu-only.
**Why:** solo lab, one source of truth already (git → tofu); a CD controller is overhead until there
are more workloads. **Consequences:** no continuous reconciliation yet; drift is caught by re-plan.

---

## Compute, OS & provisioning

### ADR-010 — Kubernetes on Talos Linux
**Status:** Accepted (2026-05-24). **Decision:** Talos as the node OS for the cluster.
**Considered:** k3s/RKE2 on Rocky/Ubuntu (the original work-migration direction was Rocky+Rancher);
full-OS + kubeadm; Harvester.
**Why:** immutable, API-driven (no SSH/shell), config-as-data — fits boot-from-git and reproducibility;
runs equally on Proxmox VMs, bare metal, and AWS EC2 (DR story). **Consequences:** mindset shift
(everything via `talosctl`); machine-config + Image Factory schematics replace cloud-init.

### ADR-011 — Hybrid topology: Proxmox + Talos VMs **and** bare-metal Talos
**Status:** Accepted (2026-05-24). **Decision:** powerful box (X99 Xeon) runs Proxmox hosting Talos
VMs; modest boxes run bare-metal Talos; all one cluster.
**Considered:** all-VM (waste metal), all-bare-metal (no instant-reset sandbox), Harvester HCI.
**Why:** Proxmox = "IPMI for VMs" (console+power for virtual), snapshot=reset sandbox; metal = the real
target and cheap to add. **Harvester ruled out** — single-node gives no HA/live-migration and wants
~32 GB/8-core just to test (built for 3-node HCI). **Consequences:** two node "shapes"; keep
hardware assumptions in swappable node modules (`proxmox.tf`/`metal.tf`) so the cluster layer stays portable.

### ADR-012 — Provisioning: Matchbox per-MAC PXE, disk-by-default / install-on-flag
**Status:** Accepted (2026-05-24, built 2026-06). **Decision:** a per-MAC table (Matchbox) decides
each box's role; boxes boot local disk by default and only PXE-install when their MAC is flagged.
**Considered:** MAAS (heavy), Sidero **Metal** (deprecated) / **Omni** (SaaS/BUSL), manual USB only.
**Why:** lightweight, DIY, local-first, has an OpenTofu provider; disk-by-default avoids reinstall
loops; central forced wipe = flip a flag + power-cycle. **Omni** kept as the managed escape hatch if
DIY gets painful. **Consequences:** Matchbox runs on a Proxmox **LXC** (out-of-cluster, survives
`tofu destroy`); a separate proxy-DHCP/TFTP on the LXC (OPNsense's dnsmasq won't emit the bootfile).
Some boxes still need a one-time USB/BIOS visit (ThinkCentre) — the argument for vPro/AMT boxes.

### ADR-013 — Remote power/management without IPMI: WoL + smart plugs (+ future AMT)
**Status:** Accepted (2026-05-24). **Decision:** power-cycle via Wake-on-LAN (power-on) and Home
Assistant smart plugs (hard cycle); prefer Intel vPro/AMT mini-PCs for *new* fleet boxes.
**Considered:** buying IPMI/BMC servers. **Why:** principle #8 — budget-conscious, secondhand x86 has
no IPMI. **Consequences:** AMT is a powerful plane → must be strong-password'd, LAN-only, patched.

### ADR-014 — Talos upgrades: never upgrade a nocloud VM in place
**Status:** Accepted (2026-06). **Decision:** add Talos extensions by baking them into the VM **image**
(`image.tf` schematic) and recreating; **never** `talosctl upgrade` a Proxmox *nocloud* VM. Metal
nodes upgrade in place fine. **Considered:** in-place upgrade everywhere (simpler).
**Why:** a nocloud VM reboot after upgrade loses its cloud-init static IP/hostname and rejoins as a
ghost. **Consequences:** VM extension changes are `tofu apply -replace`; documented as a hard safety rule.

---

## Networking

### ADR-020 — CNI: Cilium, kube-proxy-free
**Status:** Accepted (2026-05-24). **Decision:** Cilium 1.19 as the CNI, replacing kube-proxy (eBPF).
**Considered:** Calico, Flannel. **Why:** eBPF datapath, native BGP control plane (see ADR-021),
modern standard (principle #5). **Consequences:** Cilium owns LB IPAM + BGP.

### ADR-021 — Service exposure: Cilium BGP ↔ OPNsense FRR (not MetalLB)
**Status:** Accepted (2026-05-24). **Decision:** Cilium advertises LoadBalancer VIPs from a dedicated
`192.168.40.0/24` over BGP to OPNsense (FRR); cluster ASN 64513 ↔ router 64512. Only Services labelled
`bgp=advertise` are advertised. **Considered:** MetalLB (L2/ARP), Calico-BGP.
**Why:** the router actually learns the routes (natively routable from LAN/VPN, no ARP tricks/speaker
pods); both ends as code (CiliumBGP* CRDs + O-X-L `frr_bgp_*` Ansible). **Consequences:** L2
auto-discovery does **not** cross the L3/BGP boundary; LB IPs come from a separate block (no LAN IP scarcity).

### ADR-022 — Router as code: OPNsense via the `oxlorg.opnsense` Ansible collection
**Status:** Accepted (2026-05). **Decision:** manage OPNsense (BGP, ACME, HAProxy, Unbound) as code
with the O-X-L collection, run through `scripts/opnsense-playbook.sh`. **Considered:** pfSense, manual GUI.
**Why:** no click-ops (principle #3); OPNsense has the API + an Ansible collection. **Consequences:**
the collection **pin must track the os-frr/OPNsense version** (currently `25.7.8` for os-frr 1.52 /
OPNsense 26.1); the generic `raw` module needs `action: post` for mutations; `unbound_host` needs a
reconfigure handler. (pfSense config backup is legacy — slated for deletion, see PUBLISH-CHECKLIST.)

### ADR-023 — LAN DHCP: dnsmasq, not ISC dhcpd
**Status:** Accepted (2026-06). **Decision:** LAN DHCP via OPNsense dnsmasq, rebuilt idempotently by
`opnsense/dnsmasq-dhcp.py`; dnsmasq is DHCP-only (`port=0`) so Unbound keeps `:53`.
**Considered:** keep ISC dhcpd. **Why:** ISC has no settings API → can't be driven as code.
**Consequences:** PXE proxy-DHCP is separate (on the Matchbox LXC); ISC must be disabled in the UI
once (no API) for reboot-safety.

---

## Storage

### ADR-030 — Distributed storage: Longhorn (not Ceph/Rook, not hostPath)
**Status:** Accepted (2026-06). **Decision:** Longhorn as the default StorageClass (replica=2, zone
soft-anti-affinity); all stateful services moved off node-pinned hostPath onto Longhorn PVCs.
**Considered:** **Ceph/Rook**, hostPath/local-path-provisioner, NFS.
**Why:** **Ceph is the heavyweight HA target but wants ≥3 nodes and real resources** — deferred to the
future 3-node Proxmox HA build (see ROADMAP "HA model"). Longhorn is light, k8s-native, replicates on a
small heterogeneous fleet, and removes the single-node-disk SPOF that hostPath had. NFS rejected for the
SQLite recorder. **Consequences:** HA + Prometheus TSDB are now replicated (no SPOF). Longhorn disks
must live under `/var/lib/longhorn`; a `longhorn-fast` (replica=1, node-local) tier uses the
ThinkCentre's Optane for scratch. Ceph remains the likely choice **when** the 3-node cluster exists.

---

## Services

### ADR-040 — Home Assistant: HA **Container** on k8s, greenfield
**Status:** Accepted (2026-05-24). **Decision:** run the HA Container image as a Deployment with a real
PV; rebuild config greenfield (no migration). **Considered:** HAOS/Supervised (no add-on supervisor in
k8s), migrating the old instance. **Why:** design for k8s from the start, no migration baggage;
add-ons become their own workloads (Mosquitto, Zigbee2MQTT, ESPHome). **Consequences:** config kept in
git (`homeassistant/ha-config/`), applied imperatively (`kubectl cp` + restart); recorder = SQLite on a
Longhorn PVC (external Postgres an option later).

### ADR-041 — HA radios: network-attached coordinator (not USB passthrough)
**Status:** Open / planned (2026-05-24). **Decision:** use a networked Zigbee/Z-Wave coordinator (e.g.
SLZB-06) so the HA pod isn't pinned to the node with the USB stick. **Considered:** USB passthrough +
`hostNetwork`. **Why:** lets HA schedule anywhere. **Consequences:** coordinator hardware still to buy;
until then HA has no local radios (ESPHome-over-WiFi devices like the Droplet work today).

### ADR-042 — Monitoring: kube-prometheus-stack, scrape **only** Home Assistant
**Status:** Accepted (2026-06-02). **Decision:** Prometheus/Grafana/Alertmanager in-cluster; Prometheus
scrapes a single target — HA's `/api/prometheus`. **Considered:** scraping each ESP device; a cloud
monitoring SaaS. **Why:** devices already push state into HA over the persistent native API → zero added
WiFi traffic, no double-scrape, every future HA entity is monitored for free. **Consequences:**
Alertmanager webhooks back into HA for notifications; one scrape token; needs the `monitoring` ns
labelled PodSecurity=privileged (node-exporter host access).

### ADR-043 — UniFi controller: in-cluster Network Application (not UniFi OS Server, not the T61)
**Status:** Accepted (2026-06). **Decision:** run linuxserver `unifi-network-application` + Mongo on
Longhorn in-cluster (VIP `192.168.40.12`); APs adopt via the inform host `ubiquiti.teststuff.net`.
**Considered:** UniFi OS Server, keeping the Docker controller on the (now dead) T61.
**Why:** the T61 is retired; **UniFi OS Server needs privileged/systemd-PID1 and won't run on Talos**.
**Consequences:** image pinned by digest; devices re-inform on reboot; no UniFi-OS features.

### ADR-044 — Compute tiering: laptops tainted "ephemeral"
**Status:** Accepted (2026-06). **Decision:** ThinkPad metal nodes (wk-metal-01/02) carry an
`homelab.io/ephemeral` taint so Longhorn/stateful workloads avoid them; they're the compute/burst tier.
**Considered:** treat all nodes equally. **Why:** laptops are far more power-efficient (measured ~64%
better perf/W, see `docs/power-measurements.md`) but come and go / hold no replicas. **Consequences:**
stateful data stays on the desktop/SFF storage nodes (wk-02, thinkcentre, hp-01).

---

## Remote access, DNS & edge security

### ADR-050 — Remote access transport: Cloudflare Tunnel
**Status:** Accepted (2026-06). **Decision:** reach Home Assistant from anywhere via a Cloudflare Tunnel
(`cloudflared`, outbound-only, in-cluster). **Considered:** WAN port-forward, WireGuard/Tailscale.
**Why:** no port-forward, hides the home WAN IP, works behind CGNAT/dynamic IP; aligns with the planned
public-tier edge. Trade-off vs WireGuard: TLS terminates at the CF edge (a conscious SaaS exception at
the public edge, principle-noted and replaceable). **Consequences:** `ha.teststuff.net` only; LAN names
stay on local HAProxy. The HA companion app's External URL must be `ha.teststuff.net`.

### ADR-051 — Remote access auth: client-certificate **mTLS** at the WAF (not Cloudflare Access)
**Status:** Accepted (2026-06; corrects an earlier wrong call). **Decision:** enforce client-cert mTLS
via **Application-Security / SSL Client Certificates** + a WAF custom rule
(`not cf.tls_client_auth.cert_verified` → block), on top of HA's own login.
**Considered:** **Cloudflare Access mTLS** (Zero-Trust) — found to be **Enterprise-only**; HA-login-only
(weaker). **Why:** Access mTLS isn't on this plan, but **app-security mTLS works on the Free zone plan**;
the phone presents a `.p12` at the TLS handshake so the **companion app keeps working** (no interactive
login to choke on). **Consequences:** managed-CA client cert + per-host mTLS + WAF rule, all in
`tofu/cloudflare/`. (Earlier notes claiming mTLS was impossible / needing `Access:*` token scopes are superseded.)

### ADR-052 — DNS authority: `teststuff.net` moved Route53 → Cloudflare; ACME follows
**Status:** Accepted (2026-06). **Decision:** repoint the registrar NS to Cloudflare; the old Route53
hosted zone is orphaned (pending deletion). OPNsense ACME DNS-01 switched Route53 → **Cloudflare**.
**Considered:** keep DNS on Route53 and only tunnel. **Why:** one DNS control plane at the edge we're
already using; needed for the tunnel hostname + edge features. **Consequences:** **renewals break if ACME
isn't swapped** (LE queries the authoritative NS = Cloudflare) — so `opnsense-acme.yml` now uses
`dns_cf`; a scoped `homelab-acme-dns` token (Zone:Read+DNS:Edit) lives on OPNsense. Orphaned Route53
zone `ZCGRPARGVE3CW` still to be deleted (`docs/cloudflare.md`).

### ADR-053 — Cloudflare as code: OpenTofu official provider (not Crossplane); scoped per-job tokens
**Status:** Accepted (2026-06). **Decision:** manage Cloudflare with the official `cloudflare/cloudflare`
OpenTofu provider (pinned **v5**); mint **scoped, per-job API tokens** as code (`tofu/cloudflare-token/`),
never one god-token. **Considered:** Crossplane CF providers (community/Upbound, lag on Zero-Trust/Tunnel);
the Global API Key. **Why:** official provider tracks Tunnel/ZT; least-privilege RBAC (principle-aligned).
**Consequences:** a privilege boundary — the write token is minted once with an admin token *outside the
jail*; the agent only ever holds the scoped token. Provider **v5 renamed resources** (object-form tunnel
config, no `.cname`, `dns_record.content`) — verified against the Docs MCP, not model memory.

### ADR-054 — Reproducible client-cert packaging
**Status:** Accepted (2026-06). **Decision:** key+CSR from the pinned `hashicorp/tls` provider, signed by
Cloudflare's **managed CA**; openssl only wraps the PKCS#12, **pinned via devbox** with **explicit
algorithms** (`scripts/make-client-p12.sh`). **Considered:** ad-hoc system `openssl` with default
algorithms. **Why:** openssl defaults drift across versions and have silently broken mTLS imports
(RC2/3DES→AES, MAC alg); reproducibility + explicitness (user feedback). **Consequences:** never
interactive openssl; emit a `.der` for diffing certs on asn1js (a `.p12` isn't byte-reproducible).

---

## Cloud accounts & secrets

### ADR-060 — AWS auth: IAM Identity Center SSO only (no static admin keys)
**Status:** Accepted (2026-06). **Decision:** humans use `aws sso login` (profile `rasmus`, 12 h tokens);
no root, no static admin keys. The headless jail uses a **scoped read-only** key (`homelab-aws-audit`).
**Considered:** root user, long-lived IAM access keys. **Why:** least-privilege, no long-lived god-creds.
**Consequences:** scripts must fail with an `aws sso login` hint, never prompt for static keys.

### ADR-061 — Secrets: out-of-repo creds now; SOPS+age before public
**Status:** Open / planned (2026-05-24). **Decision:** all credentials live outside git under
`~/.claude/` today; anything that must live in git will be SOPS+age-encrypted before publishing.
**Considered:** sealed-secrets, Vault, plaintext. **Why:** repo is public-by-default (principle #9);
SOPS+age is simple and git-native. **Consequences:** mandated by `PUBLISH-CHECKLIST.md`; tofu state,
`*.tfvars`, `kubeconfig`, `talosconfig` gitignored.

---

## Open / undecided

### ADR-071 — Presence detection for presence-gated watering: source + privacy boundary undecided
**Status:** Open (2026-06). **Decision:** none yet. The office-plants service wants to water only when
**nobody is home** (phone-on-WiFi presence). Two open questions: **(a) source** — UniFi controller
(true AP association state; leaning) vs OPNsense (DHCP/ARP — unreliable for presence); **(b) shape** —
because neither can scope a token to *just* a home/away boolean, the privacy-preserving design is a
small **detector service** that reads presence with a least-privilege read-only credential, reduces it
to a **single boolean**, and **writes only that** to Home Assistant (never a queryable endpoint/metric;
no other cluster service learns presence). Likely the lab's **first custom-code service**. Full writeup:
[`office-plants/README.md` §8](office-plants/README.md#8-next-steps). **Consequences:** when built, this
gets its own service doc + an ADR supersede; may warrant a Cilium NetworkPolicy isolating the detector + HA.

### ADR-070 — Local caching tier (images / nix / apt): undecided
**Status:** Open (2026-05-24). **Decision:** none yet — leaning to an out-of-cluster, always-on LAN box
running **Zot or Harbor** as a pull-through image cache (consumed via Talos `registries.mirrors`), plus
maybe a nix substituter + apt-cacher-ng. **Considered:** Harbor, Zot, `distribution/registry`, Spegel
(in-cluster P2P), Squid (rejected). **Why pending:** weight vs benefit; which host. **Consequences:**
repeated pulls still hit upstream / rate-limits until decided.

---

_When a decision here changes, update the block (mark **Superseded** and add the new one) rather than
deleting history — the record is the point._
