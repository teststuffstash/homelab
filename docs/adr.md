# Architecture Decision Record (ADR)

A single-page log of the **significant decisions** behind this homelab: what was considered, what
was chosen, and why. Companion to [`CONTEXT.md`](../CONTEXT.md) (the decision *lens*),
[`ROADMAP.md`](../ROADMAP.md) (the *plan*) and [`ARCHITECTURE.md`](../ARCHITECTURE.md) (the *shape*).

Format: lightweight ADRs (one block each). **Status:** Accepted / Superseded / Open. Dates are when
the call was made; most trace to the 2026-05 planning and the 2026-06 build. Decisions are weighed
against the `CONTEXT.md` principles — reproducible-from-git, deterministic diffs, local-first,
open-source/replaceable, budget-conscious, public-by-default.

> Newest decisions are at the bottom of each area. **Edit a block in place** for small corrections or
> details settled during implementation. Reversing a **significant, established** decision instead gets
> a **new ADR**, with the old one marked `Superseded-by` (e.g. swapping Garage for a MinIO fork, or
> LAN-only → public). Keep blocks to **one decision** — operational detail belongs in `docs/`, and
> application design belongs in the app's own repo (ADR-004).

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
**Status:** Superseded-by ADR-005 (2026-06-17). **Decision:** drive the cluster with `tofu apply` (+ a Helm provider)
today; add a GitOps controller later. **Considered:** ArgoCD vs Flux vs tofu-only.
**Why:** solo lab, one source of truth already (git → tofu); a CD controller is overhead until there
are more workloads. **Consequences:** no continuous reconciliation yet; drift is caught by re-plan.

### ADR-005 — GitOps: ArgoCD reconciles the app layer; `tofu` keeps the substrate
**Status:** Accepted (2026-06-17, supersedes ADR-003). **Decision:** **ArgoCD** is live — installed +
seeded by `tofu/argocd.tf`, then an app-of-apps (`argocd/`) reconciles the platform/app layer from git.
Governing rule: **anything ArgoCD needs in order to run cannot be ArgoCD-managed**, so the substrate
(cluster, Cilium, Longhorn, CloudNativePG, Infisical, ESO, ArgoCD itself + their bootstrap secrets)
stays in `tofu`; ArgoCD owns everything downstream. **Source = GitHub for now**, cut over to self-hosted
Forgejo later (follow-up). **Considered:** Flux; ArgoCD sourced from Forgejo at bootstrap (a Forgejo→
Postgres→ArgoCD chicken-and-egg); staying tofu-only (ADR-003). **Why:** enough workloads now (the
secrets stack + real apps) to want continuous reconciliation; the GitHub seed sidesteps the Forgejo
bootstrap paradox while keeping the offline-resilience goal reachable. **Consequences:** sync-waves order
CNPG → Postgres → Infisical → ESO; UI at `argocd.teststuff.net`; bootstrap secrets seeded from KeePass
(ADR-062); Forgejo cutover tracked as FU-007 in `docs/follow-ups.md`. See `argocd/README.md`.

### ADR-004 — Repo topology: homelab is the platform; apps live in their own repos
**Status:** Open / planned (2026-06-13). **Decision:** treat this repo as the **platform** (clusters,
networking, storage, observability, shared services) and build each **application** in its **own repo**
with its own Helm chart and docs; homelab carries only the app's **platform wiring** — its ArgoCD
**Application** manifest + values, and the platform resources it needs (buckets, DB, DNS, OIDC client).
**Considered:** monorepo with apps + service docs inside homelab (the early-work state — feels wrong as
apps grow); fully separate with no homelab footprint (rejected — platform resources must be code here).
**Why:** clean platform/product separation; apps get independent CI/release/versioning; matches the
ArgoCD **app-of-apps** model. Evolves ADR-003 — adopting ArgoCD is the delivery half; until then an app
can be wired via `tofu apply`+Helm against the same chart. **Consequences:** new apps start as their own
repo; homelab gains an `apps/` (ArgoCD Applications) area when ArgoCD lands; **service-implementation
docs leave homelab for their app repos** (so the sleep-tracking build doc lives in its app repo, ADR-045).

### ADR-074 — Platform resources are app-owned (apps provision their own buckets/keys/DBs)
**Status:** Accepted (2026-06-14; supersedes part of ADR-045). **Decision:** the platform provides a
**capability** (the Garage store, later Postgres, an OIDC issuer, …) plus a thin **admin seam**; each
**app declares the instances it needs — buckets, keys, grants, databases — from its own repo** (ADR-004)
and consumes the generated secret in its own namespace. homelab creates **no** app buckets and holds
**no** app keys. **Considered:** homelab centrally owning every app's buckets/keys (the earlier ADR-045
position — rejected: every new app needs a homelab PR, app repos aren't self-contained, contradicts the
per-app-repo model). **Why:** clean platform/product separation; apps get independent lifecycle; matches
the app-of-apps direction. **Consequences:** the platform must expose a provisioning seam (admin API +
token); cross-app sharing is **bucket-owner-grants-consumer** (e.g. snore-recorder grants the
sleep-tracking ingester read on `sleep-snore`). Reusable how-to: `docs/patterns/app-owned-resources.md`;
mechanism: ADR-075.

### ADR-075 — App resource-provisioning mechanism: app-repo tofu now, Crossplane later
**Status:** Superseded-by ADR-076 (2026-06-17). **Decision:** apps provision their Garage resources from their own
repo's **tofu** using the **`jkossis/garage`** provider (Terraform registry), reaching the admin API via
a `kubectl` port-forward (`infra/apply.sh`). **Considered / deferred:** a **Crossplane Garage provider**
for app-declared CRs reconciled in-cluster (the steady state once a control plane lands) — but the only
native one (`kikokikok`) is **too immature** to trust with key material (1★, AI-scaffolded, stale); the
likely bridge is Crossplane **`provider-terraform`** wrapping the same `jkossis` module. **Why:** no
control plane yet ("tofu now, ArgoCD later", ADR-003); build-time trust (runs only during apply) beats a
standing in-cluster controller holding admin creds. **Consequences:** each app carries `infra/` (tofu +
a port-forward wrapper); keys land in the app's local state (SOPS+age before public, ADR-061). Migrating
to Crossplane is a re-point at the same provider.

### ADR-076 — App resource provisioning: Crossplane provider-terraform (the "later" landed)
**Status:** Accepted (2026-06-17, supersedes ADR-075). **Decision:** now that ArgoCD is live (ADR-005),
app Garage resources are reconciled **in-cluster** by **Crossplane `provider-terraform`**
(`xpkg.crossplane.io/crossplane-contrib/provider-terraform`) wrapping the same `jkossis/garage` module —
declared as a `Workspace` CR in the **app's own repo** (ADR-074) and synced by ArgoCD. The Garage admin
credential reaches the provider pod via **ESO** (Infisical → `garage-admin` secret → pod env), so the
standing controller never holds a git-borne secret; TF state is a kubernetes-backend secret in
`crossplane-system`. **Considered:** keeping app-repo tofu (ADR-075 — manual `apply.sh`, no continuous
reconciliation); a native Garage Crossplane provider (still too immature, ADR-075). **Why:** GitOps
reconciliation + drift-correction for app resources, the steady state ADR-075 deferred. **Consequences:**
the generated key lands in a connection `Secret` and is **published to Infisical by the Workspace
itself** (the Infisical TF provider in provider-terraform, authed by the `crossplane-tf-writer` UA
identity) — **not** via ESO PushSecret, because the ESO Infisical provider is **read-only**
(`ClusterSecretStore` capabilities = `ReadOnly`). In-cluster consumers read that key back via an ESO
`ExternalSecret`; **offline devices read their secrets from Infisical at provision time** (written as
plaintext `mode 600` files on the device — no sops, ADR-062), since ESO can't reach them. Apps with
**pre-existing data** (sleep-tracking) **adopt** their resources via config-driven
`import` blocks + `deletionPolicy: Orphan` (never recreate); their key secrets are published to Infisical
from the old state instead. Per-app-repo needs an ArgoCD repo credential. Migrated 2026-06-17:
snore-recorder (`sleep-snore`, created fresh) and sleep-tracking (`sleep-band`/`sleep-db`, adopted).

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
reconfigure handler. (The legacy pfSense config backup + the `rocky/`/`netboot.xyz/` dirs were deleted for publish.)

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

### ADR-031 — Self-hosted S3 object store: Garage (not MinIO)
**Status:** Accepted (2026-06-13). **Decision:** run **Garage** (Deuxfleurs) as the in-cluster
S3-compatible object store, introduced as the convergence point for the sleep-tracking pipeline
(ADR-045); candidate to later also serve the Longhorn/HA backups currently sent to external S3/B2.
**Considered:** **MinIO** (rejected — community edition went maintenance-mode and had console/features
gutted in 2025; fresh forks e.g. OpenMaxIO too unproven for personal data); **SeaweedFS** (more
features — filer, tiering — but more moving parts; the fallback if scale grows); **Ceph/Rook RGW**
(deferred with Ceph itself to the 3-node HA build, ADR-030); external **AWS S3 / Backblaze B2**
(third-party custody of private data). **Why:** single Rust binary, light on the heterogeneous fleet,
S3 `Put/GetObject` is all the pipeline needs, actively developed, deployable via Helm under ADR-003.
Self-hosting keeps private data on-infra (vs the external S3 used only for backups). **Consequences:**
auth is **per-bucket access keys** (read/write/owner), **not** AWS-style prefix IAM — isolation is by
**separate buckets**. Obeys "data is the only non-code thing → bucket-id in git": layout/config is
code, the bytes are data. Deploy/access/ops live in **`docs/garage.md`**. Follow-on decisions split
out: access model → **ADR-073**, who owns buckets → **ADR-074**, provisioning mechanism → **ADR-075**.

### ADR-073 — Garage access model: LAN-only
**Status:** Accepted (2026-06-14). **Decision:** expose the Garage S3 API **on the LAN only** —
in-cluster consumers use the ClusterIP Service; LAN clients use `s3.teststuff.net` (OPNsense HAProxy →
BGP VIP 192.168.40.16, valid Let's Encrypt cert). Admin (3903) + RPC (3901) stay cluster-internal.
**Considered:** a **Cloudflare tunnel** (rejected — its 100 MB body cap blocks bulk/backup objects,
and the only off-LAN writer, the phone's Gadgetbridge export, runs on home WiFi); a **public
LoadBalancer** (rejected — exposes the home IP + an always-on S3 port for no gain). **Why:** every real
consumer is in-cluster or on-LAN, so keep the attack surface at zero — consistent with "only HA is
public" (ADR-050/051). **Consequences:** off-LAN access would be a deliberate future decision;
endpoints/VIP/HAProxy detail in `docs/garage.md`.

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

### ADR-043 — UniFi controller: in-cluster Network Application (not UniFi OS Server)
**Status:** Accepted (2026-06). **Decision:** run linuxserver `unifi-network-application` + Mongo on
Longhorn in-cluster (VIP `192.168.40.12`); APs adopt via the inform host `ubiquiti.teststuff.net`.
**Considered:** UniFi OS Server, keeping the previous Docker-based controller.
**Why:** the previous controller host was retired; **UniFi OS Server needs privileged/systemd-PID1 and won't run on Talos**.
**Consequences:** image pinned by digest; devices re-inform on reboot; no UniFi-OS features.

### ADR-044 — Compute tiering: laptops tainted "ephemeral"
**Status:** Accepted (2026-06). **Decision:** ThinkPad metal nodes (wk-metal-01/02) carry an
`homelab.io/ephemeral` taint so Longhorn/stateful workloads avoid them; they're the compute/burst tier.
**Considered:** treat all nodes equally. **Why:** laptops are far more power-efficient (measured ~64%
better perf/W, see `docs/power-measurements.md`) but come and go / hold no replicas. **Consequences:**
stateful data stays on the desktop/SFF storage nodes (wk-02, thinkcentre, hp-01).

### ADR-045 — Sleep-tracking: first application on the per-app-repo model
**Status:** Accepted (2026-06-13; build pending). **Decision:** build sleep-tracking as a standalone
**app in its own repo** (ADR-004); homelab holds only its **platform wiring** — a Postgres instance,
the ArgoCD Application + values, and a future OIDC client (ADR-055). The app **owns its Garage
buckets/keys** (`sleep-band`, plus a cross-read on snore-recorder's `sleep-snore`) per **ADR-074**,
declared from its repo. **Why:** first exercise of the platform/app split — it proves the
app-owned-resources pattern (ADR-074/075) end-to-end. **Consequences:** the app **design** (data
sources, the nightly ingester → Postgres, audience-split presentation) lives in the **sleep-tracking
repo** (`docs/ARCHITECTURE.md`), not here; the "Others" presentation is gated on the IDP (ADR-055/072).
Garage store = ADR-031.

### ADR-046 — Postgres platform service: CloudNativePG
**Status:** Accepted (2026-06-17). **Decision:** **CloudNativePG** (operator) provides Postgres as a
platform service — one HA `Cluster` CR per consumer, in the consumer's namespace. First consumers:
**Infisical** (ADR-062), **sleep-tracking** (ADR-045), and Forgejo (on cutover). **Considered:** the
chart-bundled (bitnami) Postgres per app, the Zalando operator, an external managed DB. **Why:**
k8s-native, declarative HA + failover + backups; it was the lynchpin that unblocked Infisical, Forgejo-
for-real, and sleep-tracking at once. **Consequences:** when `tofu` must build a connection string, the
app role password is **supplied** (a basic-auth secret referenced by `bootstrap.initdb`) rather than
operator-generated, so the string always matches; Postgres is now **LIVE** in `SERVICES.md` (sleep-
tracking's DB steps are unblocked). In-cluster app↔DB uses `sslmode=disable` (CNPG self-signed cert;
traffic is pod-to-pod).

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

### ADR-055 — Custom OIDC IDP for "Others" (planned)
**Status:** Open / planned (2026-06-13). **Decision:** stand up a **custom, self-hosted OIDC IDP** to
authenticate **Others** — non-homelab people granted read-only access to specific apps (e.g. the sleep
dashboard, ADR-072) — kept separate from my own admin access (mTLS, ADR-051). **Considered:** off-the-
shelf IDPs (Authentik, Keycloak, Zitadel, Authelia) vs a **custom build** — chose custom to fit the
intended users' familiar login methods; per-app passwords / magic-links rejected (stopgap, don't scale).
**Why:** one revocable, least-privilege login plane for externally-shared apps, instead of asking non-
technical people for `.p12` client certs (ADR-051) they can't install. **Consequences:** a new public-
tier component; shared apps become OIDC clients; ties into the not-yet-built public tier + Cilium
NetworkPolicy isolation. Design is tracked out-of-repo in the private business repo; built when the
first externally-shared app (the sleep "Others" page) needs it.

---

## Cloud accounts & secrets

### ADR-060 — AWS auth: IAM Identity Center SSO only (no static admin keys)
**Status:** Accepted (2026-06). **Decision:** humans use `aws sso login` (profile `rasmus`, 12 h tokens);
no root, no static admin keys. The headless jail uses a **scoped read-only** key (`homelab-aws-audit`).
**Considered:** root user, long-lived IAM access keys. **Why:** least-privilege, no long-lived god-creds.
**Consequences:** scripts must fail with an `aws sso login` hint, never prompt for static keys.

### ADR-061 — Secrets: out-of-repo creds now; SOPS+age before public
**Status:** Superseded-by ADR-062 (2026-06-17). **Decision:** all credentials live outside git under
`~/.claude/` today; anything that must live in git will be SOPS+age-encrypted before publishing.
**Considered:** sealed-secrets, Vault, plaintext. **Why:** repo is public-by-default (principle #9);
SOPS+age is simple and git-native. **Consequences:** tofu state,
`*.tfvars`, `kubeconfig`, `talosconfig` gitignored. _Update:_ **SOPS+age was ultimately NOT adopted
anywhere** (ADR-062) — in-cluster secrets use Infisical+ESO, bootstrap uses KeePass, and the offline
`snore-recorder` device reads its secrets from Infisical at provision time (plaintext `mode 600` on the
device; `sops-nix` was dropped — the age key would sit on the same card as the ciphertext, so it bought
nothing). The "no plaintext secrets *in git*" rule still holds; the gitignore guards stand.

### ADR-062 — Secrets platform: KeePass (Tier-0) + Infisical + ESO
**Status:** Accepted (2026-06-17, refines ADR-061). **Decision:** three tiers (full how-to:
[`docs/secrets.md`](secrets.md)) — **(0)** root/bootstrap creds the cluster can't decrypt for itself
live in a **KeePass** wallet (out-of-repo, seeded to `tofu` via `scripts/keepass-env.sh`); **(1·2)**
every in-cluster secret lives in **self-hosted Infisical** (on CloudNativePG, ADR-046) and is delivered
to workloads by the **External Secrets Operator** (`ExternalSecret` → namespace `Secret`); the offline
`snore-recorder` device (which ESO can't reach) **reads its secrets from Infisical at provision time** and
stores them as plaintext `mode 600` files on the SD card. **SOPS+age is not used at all** — on the device
`sops-nix` gave no at-rest benefit (the age key lives on the same card as the ciphertext).
**Considered:** SOPS-everywhere (ADR-061 — ArgoCD needs a decrypt plugin, no rotation/UI, and the team-
sharing benefit is moot solo); **sealed-secrets** (lightest, but no UI/rotation/audit); **Vault/OpenBao**
(heavier than wanted); **keeenv/KeePass-as-the-backend** (no ESO provider — kept as the human Tier-0
layer instead). **Why:** an ESO backend was needed regardless; Infisical **self-hosts** (principle),
adds rotation/audit/UI, and lets ArgoCD stay dumb (just syncs `ExternalSecret`s, no SOPS plugin).
**Consequences:** Infisical bootstrapped via the chart's `autoBootstrap` (admin creds in KeePass, signups
then disabled); its project + read-only `eso-reader` machine identity are created declaratively by
`tofu/infisical/` (Infisical TF provider, authing with the non-expiring instance-admin token — the one
bootstrap seam); add an app secret = `devbox run infisical-secret` + an `ExternalSecret`. Crossplane
(ADR-075) is no longer needed to deliver secrets.

---

## Agent platform

Full design + trust model + the worked sleep-tracker example: [`agents/`](agents/README.md). These
records are intentionally thin; the narrative lives in the design doc.

### ADR-077 — Agent runtime: Goose (leaning), wrapped by agent-sandbox
**Status:** Proposed (2026-06-25, leaning Goose). **Decision:** the per-task coding/triage agents run
**Goose** recipes (model as a config knob via `claude-or`/OpenRouter, MCP-native, subagents, sandbox
mode, vendor-neutral under the Linux Foundation). The agent itself is boot-from-git: the recipe is the
reproducible spec (`<app>/.agents/*.yaml`), only the model key is out-of-repo. **Considered:** Claude
Code + Docker jail (Anthropic-locked); opencode (model-agnostic, no jail); raw Hermes; **Omnigent** as a
meta-harness *above* harnesses (deferred — adopt only if governing multiple harnesses becomes real, see
ADR-081 for the one Omnigent pattern we do take). **Consequences:** still evaluating in practice; the
recipe format is portable enough that the runtime can change without rewriting the pipeline.

### ADR-078 — Isolation layer: agent-sandbox (k8s-native), not a mesh
**Status:** Accepted (2026-06-25). **Decision:** ephemeral agents run in
[agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) pods — a CRD-driven, recreatable
sandbox-per-task that fits boot-from-git; snapshot/restore is treated as pure cache (a dead sandbox is
re-dispatched, never resurrected). **Considered:** Omnigent's own Omnibox sandbox (overlaps; we keep
agent-sandbox as the substrate and borrow only Omnigent's egress-proxy idea); Istio/service-mesh
(rejected — heavy, and it doesn't do the hard part, ADR-081). **Consequences:** the durable artifact is
always the git branch / S3 object the task produced, not the pod.

### ADR-079 — Write policy: agents propose, GitOps applies (strict-PR)
**Status:** Accepted (2026-06-25). **Decision:** an agent's only "write" is *open a PR / push a branch*;
ArgoCD + Tofu reconcile. No imperative `kubectl apply` / `tofu apply` from an agent, except a narrow
allow-list of runbook ops that genuinely can't be expressed in git. Master is protected (branch
protection + required checks); token scope is the belt, the protection rule the suspenders.
**Considered:** letting an in-cluster agent apply directly (rejected — violates boot-from-git / no
click-ops, and makes blast radius unreviewable). **Consequences:** every agent change is a reviewable
diff; the in-cluster MCP agent is read + propose, not a generic `kubectl` passthrough.

### ADR-080 — State model: durable git/S3 is truth; context/vectors/snapshots are cache
**Status:** Accepted (2026-06-25; candidate to graduate into `CONTEXT.md`). **Decision:** the source of
truth for any agent work is durable, auditable state — **git + S3** — not conversation history, vector
stores, or sandbox snapshots, which are all disposable cache rebuildable from the durable layer. Applies
to memory too (markdown facts are durable; a vector index is cache). **Considered:** Memory-OS-style
DB/vector memory as primary (rejected as primary — opaque, un-`git diff`-able, conflicts with
reviewability; fine as a cache layer). **Consequences:** re-dispatch beats resurrect; three independent
sources converged on this (Memory-OS Layer-1, agent-sandbox state, the local-LLM "structured world
state" pattern).

### ADR-081 — Per-job identity: minted short-lived creds + Cilium egress + injection proxy
**Status:** Accepted (2026-06-25). **Decision:** no long-lived secrets in agent pods. LLM keys = a
master/provisioning key in **Infisical** mints a budget-capped, short-lived runtime key per job (the cap
is the spend guardrail). GitHub = a dedicated **"agents" GitHub App** (private key in Infisical) mints
**~1h installation tokens** scoped to specific repos+permissions per job — no hand-made per-repo PATs.
Egress = **Cilium `toFQDNs`/L7 policy** (the pod can reach only the proxy) **+ a small auth-injecting
forward proxy** that holds the minted creds and adds the headers, so the agent never sees them (the one
Omnigent pattern adopted). **Considered:** Istio EnvoyFilter header injection (rejected — drags in a
mesh to do what a ~50-line proxy does); static PATs (rejected — long-lived, hand-managed).
**Consequences:** one egress proxy is where all secrets are injected; ghcr **push** stays a classic PAT
(CI's credential, not the agent's).

### ADR-082 — CI runners: Tofu'd Proxmox VMs running ephemeral k3d
**Status:** Accepted (2026-06-25). **Decision:** the full-stack confidence gate
(`devbox run test-integration`: k3d + Garage + ingester + Grafana + Playwright) runs on **self-hosted
GitHub Actions runners that are Tofu-defined Proxmox VMs**, which create+destroy the k3d stack per PR.
The VM is infrastructure/cattle (recreatable from git); the *environment-under-test* is ephemeral — so
an always-on runner does not violate "only production is long-running." **Considered:** DinD on the slim
in-cluster ARC pods (rejected for now — needs privileged, which we avoid); off-cluster pop-os only (the
`build-image` precedent, but not declarative/owned); a dedicated CI cluster with autoscaling privileged
ARC (deferred — revisit only if parallel PR volume outgrows a VM). **Consequences:** new `tofu/`
resource + a GitHub self-hosted-runner registration; same harness gates both agent PRs and
Renovate/Dependabot bumps.

### ADR-083 — Packaging in-cluster workloads: raw manifests over Helm for simple components
**Status:** Accepted (2026-06-29). **Decision:** deploy **simple, single-component** workloads as **raw
Kubernetes manifests** (ArgoCD-synced under `argocd/resources/<svc>/`), and reserve **Helm** for charts
that **encapsulate real multi-component complexity we'd otherwise reinvent**. First applied to the
logging stack — **Loki (single-binary) + Alloy DaemonSet** are raw manifests, not the `grafana/loki` /
`grafana/alloy` charts; the **nix pull-through cache** (nginx) is likewise raw; **kube-prometheus-stack**
stays Helm. This is **orthogonal to "minimize tofu"** — raw-via-ArgoCD and Helm-via-ArgoCD are both
GitOps/no-tofu; the axis here is abstraction-vs-control, not the deploy tool.

**Pros (why raw here):** (1) **determinism** — we write the component's *real* config (Loki's
`config.yaml`) instead of guessing how chart `values` template into it, which matters when every
deploy→debug cycle is a live-cluster round-trip; (2) **small surface** — single-binary Loki + a
DaemonSet is ~4 files, vs the chart's gateway / canary / results-cache / ServiceMonitors /
multi-Deployment machinery we'd only disable; (3) **stabler schema** — component config keys churn less
than chart `values` schemas across releases; (4) **clean GitOps diffs** — what's in git is what runs, no
templating layer to reason through.

**Cons (what we accept):** (1) **we own the config across upgrades** — Renovate bumps the *image* but
won't migrate a deprecated key or `schema_config`; the chart maintainers would; (2) **we forgo
maintained operational defaults** — tuned probes, the canary self-monitor, query caching; (3) it's only
sound **because** we picked single-binary Loki — for SimpleScalable/distributed, the chart's component
wiring earns its keep. Note the `grafana/loki` chart's `loki.structuredConfig` *can* hold raw config
too, so "config control" isn't exclusively a raw benefit — this was a judgment call, not a clean win.

**Considered:** the `grafana/loki` + `grafana/alloy` charts (rejected for this simple deployment per
above); Helm with `structuredConfig` (the viable fallback). **Consequences:** raw manifests are the
default for simple custom services; if a Loki upgrade ever turns config-maintenance painful, switching to
the chart while keeping our exact config via `structuredConfig` is a small, contained, **reversible**
change. Rule of thumb: **Helm when the chart saves you from reinventing complexity; raw when the chart
is more abstraction than value.**

### ADR-084 — Three-layer repo topology + automated deploy for app stacks (sleep-iac)
**Status:** Accepted (2026-07-04). **Decision:** an app stack is split into **three layers**: (1) **app
repos** (sleep-tracking, snore-recorder) — code + chart only; on an app-relevant master push they
build+publish an image + OCI chart to ghcr; platform-agnostic (they know nothing about homelab). (2) a
**per-stack `-iac` repo** (`sleep-iac`, public) — the stack's *deploy truth*: the ArgoCD app-of-apps
(child Applications, `project: sleep`) + Helm values + the apps' infra CRs (Garage Workspaces, ESO,
`OpenRouterKey`). (3) **homelab** — the platform: operators, the stack's AppProject + namespaces, and ONE
root Application pointing at the `-iac` repo. Refines ADR-004/ADR-074 (the app still *owns* its
resources, but the declarations live in the stack's iac repo, not the app repo). Executes **FU-025**.

**The chart is the deployable unit; IaC pins ONE number.** A deploy builds the image AND packages the
chart at a single version `2026.<m>.<d>-g<sha>` (commit-date CalVer + short git sha; the sha rides as a
SemVer *prerelease* because OCI Helm requires a valid SemVer — a bare sha is illegal, and `+build` isn't
a legal OCI tag char). `chart version == appVersion == image tag`, and the chart defaults `image.tag` to
`.Chart.AppVersion`, so **`sleep-iac` sets only the chart `targetRevision`** — the image tag never
appears in IaC. Versioning is **CalVer+sha, not SemVer**: no human version decision per change, and **no
Renovate for our own artifacts** (a git-sha doesn't order, so Renovate can't drive it; it stays in its
lane — app deps, platform charts).

**Deploy is automated + CI-gated, no review.** The app repo's `deploy` workflow opens an **auto-merging**
version-bump PR in the `-iac` repo (fixed `deploy/<app>` branch ⇒ one open PR; concurrency
cancel-in-progress + a monotonic ancestor guard ⇒ no older-sha regression). The `-iac` repo gates on **CI
only** (`require_approval=false`) — a mechanical bump doesn't warrant an LLM/human review — so GitHub
auto-merges on ci-green. ArgoCD then syncs **near-instantly**: the merge's master push fires an
in-cluster `sync.yaml` that POSTs a push event to ArgoCD's native `/api/webhook`, so argocd-server stays
LAN-only (the runner reaches it, GitHub never does) instead of waiting up to ~3 min for the reconcile
poll. Workflows build artifacts via **devbox** (pinned tools; the slim ARC runner lacks helm/gh/xz);
only auth/push use provided actions.

**Sharp operational lesson (verified live):** a GitHub App's **`Integration` ruleset bypass does NOT
waive the "required approvals" pull_request rule on a *merge*** — only `OrganizationAdmin` does. So
"give the deploy bot a bypass actor" can't make its PR auto-merge past a review requirement (it stays
`REVIEW_REQUIRED`). The fix is to **drop the approval requirement** (let CI be the gate) or add a
distinct approver — not a bypass.

**Considered:** keeping the stack in-repo (homelab `argocd/sleep/`, the pre-FU-025 state) — rejected:
couples app deploy to the platform and leaves the release→deploy path manual + drifty (`Chart.yaml` vs a
`v*` tag vs ArgoCD `targetRevision`). Manual `v*` SemVer releases — rejected: a version decision per
change + lockstep chart/image bumps in IaC. Renovate driving the pin — rejected (git-sha unorderable; we
don't want Renovate touching our artifacts). A coordinator step that deploys — **superseded**: the deploy
workflow does it, so the coordinator never touches homelab (step 7a is a no-op). For instant sync: a
GitHub-delivered webhook (needs public exposure of the LAN-only argocd-server) and just lowering
`timeout.reconciliation` (not instant) — both rejected for the in-cluster webhook nudge.

**Consequences:** app repos are pure artifact producers (platform-agnostic); a deploy is a reviewable
one-line PR that's usually fully automatic; homelab behaves like a real platform (AWS/Civo), tightening
the FU-039 direction. A cross-repo deploy needs a scoped `homelab-deploy` GitHub App (contents+PR on the
`-iac` repo) whose key is a sleep-tracking-only Actions secret. sha-tagged images accumulate in ghcr → a
scheduled cleanup workflow (GitHub has no packages-retention API, so *not* tofu). Post-deploy
health/rollback is deferred (**FU-044**, in-cluster off ArgoCD events); the coordinator's context becomes
per-stack (**FU-045**). Full design + runbook: [`sleep-iac.md`](sleep-iac.md).

### ADR-085 — Agents framework & platform services published as Crossplane XRDs; stacks own their policy
**Status:** Open (direction set 2026-07-05). **Decision (direction):** homelab is a *platform*, not the
owner of each stack's agent config — it **publishes** its capabilities as Crossplane XRDs and stacks
self-serve. (1) An **`AgentStack` XRD + Composition** renders a stack's control plane (coordinator
gate/CronJob + review-reflex + RBAC + secret wiring = the MECHANISM); each stack's `-iac` repo declares
`kind: AgentStack` with its repos, model tiers, tools, git workflow and review rubric (the POLICY). The
framework *code* lives in homelab and is packaged for consumption; a stack writes a **claim**, not
machinery. (2) **Platform-service XRDs** (S3/Postgres/…) become the discovery **source of truth**,
superseding hand-maintained [`SERVICES.md`](../SERVICES.md) — discovery is a cluster query and the human
catalog is generated from the XRDs. **Considered:** keep the agents framework homelab-owned + per-stack
config files (rejected — every stack would copy scripts + config drifts; doesn't scale past ~2 stacks);
keep `SERVICES.md` as the catalog (rejected long-term — untyped, not discoverable, hand-curated).
**Why:** the boot-from-git / platform-as-API lens (ADR-084, FU-025/FU-039) — mechanism=platform,
policy=stack. **First cut (homelab-side stand-in):** `agents/stacks.json` + `agents/coordinator-scan.sh`
+ `coordinator-session.sh --stack`, with one `stacks_json()` swap-point → `kubectl get agentstacks`.
**Consequences:** a new stack = a claim in its `-iac` repo, not a homelab change; build-time service
discovery without cluster creds may still want a generated static catalog (open). Tracked: **FU-048**
(AgentStack XRD), **FU-049** (service XRDs vs SERVICES.md), **FU-045/FU-050** (per-stack coordinator +
gate). Design: [`agents/platform-and-stacks.md`](agents/platform-and-stacks.md).

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

### ADR-072 — Access for "Others" to read-only personal dashboards
**Status:** Open (2026-06-13; direction set, IDP pending). **Decision:** read-only, phone-first
dashboards (ADR-045) must be reachable by **Others** — non-technical, external, with no homelab
accounts. Auth direction: a **self-hosted OIDC IDP** (ADR-055); the minimal web page becomes an OIDC
client and Others log in there. This sidesteps the current edge, where the only public hostname is
`ha.teststuff.net` via Cloudflare Tunnel (ADR-050) gated by **client-cert mTLS** (ADR-051) that an
external person can't present. Exposure = a **non-mTLS public-tier hostname** fronting the OIDC-gated
page. **Considered:** mTLS for Others (rejected — can't ask a non-technical person to install a `.p12`);
magic-link / signed-URL (workable stopgap before the IDP); **static HTML/PDF export** shared by link
(smallest surface; fine for v1 before any live exposure); Grafana public snapshot (rejected — Grafana-
flavoured + a live surface). **Why pending:** the IDP (ADR-055) and public tier aren't built. **Consequences:**
until then, sharing is a **static export** (v1) or manual; when live, the page + IDP get a Cilium
NetworkPolicy and an ADR supersede.

### ADR-070 — Local caching tier (images / nix / apt): partially resolved
**Status:** Open (2026-05-24; nix leg resolved 2026-06). **Decision (images/apt):** none yet —
leaning to an out-of-cluster, always-on LAN box running **Zot or Harbor** as a pull-through image
cache (consumed via Talos `registries.mirrors`), plus maybe apt-cacher-ng. **Considered:** Harbor,
Zot, `distribution/registry`, Spegel (in-cluster P2P), Squid (rejected). _Update:_ the **nix** leg
landed differently than the original "out-of-cluster" lean — an **in-cluster** pull-through cache
(nginx on a Longhorn PVC, ADR-083, `argocd/resources/nix-cache/`), acceptable because losing it on
a cluster wipe only costs a re-fill and its main consumer (agent pods) lives in-cluster anyway.
**Why still open:** image-mirror weight vs benefit; which host. **Consequences:** repeated image
pulls still hit upstream / rate-limits until decided.

---

_When a decision here changes, update the block (mark **Superseded** and add the new one) rather than
deleting history — the record is the point._
