# Architecture Decision Record (ADR)

A single-page log of the **significant decisions** behind this homelab: what was considered, what
was chosen, and why. Companion to [`CONTEXT.md`](../CONTEXT.md) (the decision *lens*),
[`ROADMAP.md`](../ROADMAP.md) (the *plan*) and [`ARCHITECTURE.md`](../ARCHITECTURE.md) (the *shape*).

Format: lightweight ADRs (one block each). **Status:** Accepted / Superseded / Open. Dates are when
the call was made; most trace to the 2026-05 planning and the 2026-06 build. Decisions are weighed
against the `CONTEXT.md` principles — reproducible-from-git, deterministic diffs, local-first,
open-source/replaceable, budget-conscious, public-by-default.

> Newest decisions are at the bottom of each area. Keep blocks to **one decision** — operational
> detail belongs in `docs/`, and application design belongs in the app's own repo (ADR-004).

**The three rules that keep this file a decision log and not a design archive:**

1. **A block is ≤~20 lines.** It answers *what was chosen, what was rejected, why, what it costs* —
   nothing else. The **design** (mechanism, phases, rollout, gap registers) goes to a doc under
   `docs/` and the block links to it. If you are writing a build order or a phase list, you are
   writing a design doc; give it a file. See the routing table in `CLAUDE.md`.
2. **An accepted block is immutable in substance.** Edit in place only for typos, broken links, and
   details that *clarify* what was already decided. An **Addendum** may add evidence or narrow
   scope; it may never change the Decision line — if the decision moved, that is a **new ADR** and
   the old one gets `Superseded-by`. Two addenda on one block is the signal you should have opened
   a new ADR; three means the design belongs in `docs/`.
3. **`Status: Open` is not a parking space.** An undecided question is a follow-up (`FU-NNN`) or a
   spike (`docs/spikes/`). An Open block is legitimate only while it records *the shape of a
   decision deliberately not yet made* — and it names the trigger that will settle it.

Reversing a **significant, established** decision gets a new ADR with the old marked
`Superseded-by` (e.g. swapping Garage for a MinIO fork, or LAN-only → public).

_Blocks written before these rules (notably ADR-084/092/093/094/096, all >50 lines) are
**grandfathered**: they get split into decision + design doc **when next substantively touched**,
not in a sweep — several describe designs still being built, and churning them mid-build is how
the design and the record drift apart. ADR-096's design home is
[`agents/model-routing.md`](agents/model-routing.md); ADR-093/094's is
[`agents/workflow.md`](agents/workflow.md) + [`agents/merge-path.md`](agents/merge-path.md)._

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
**Status:** Open (direction set 2026-07-05; first cut built + ran live; **AgentStack XRD BUILT 2026-07-12,
oracle on a claim — FU-048, `docs/agents/agentstack.md`; FU-049 service XRDs still open**). **Decision (direction):** homelab is a *platform*, not the
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

### ADR-086 — Coordinator write tier W1: spec gap-flags on open agent PR branches
**Status:** Accepted (2026-07-10, operator-directed). **Decision:** the coordinator gains its first
DIRECT-write capability (FU-059 tier W1): during a merge-forward arbitration it commits **⚑ gap
flags into `specs/`** — on the requirement the shortfall violates — **pushed to the open agent PR
branch only**, so the flag merges WITH the code that carries the gap and the fixing PR deletes it.
`git log` on the spec file becomes the audit trail of every known shortfall and its resolution.
**Scope is the whole point:** W1 = spec gap-flag lines on open agent PR branches. Never master
directly, never code, never `.agents/`/CI — those stay label/comment/merge-only (ADR-079) or
human-gated. Order matters operationally: flag FIRST, then dispatch the re-review
(dismiss-stale-on-push would void an approval landed before the flag). **Considered:** GitHub
issues as the arbitration record (rejected — issues are ephemeral work pointers with no audit
value; an auditor must never dig through closed issues to learn why code is the way it is);
homelab `follow-ups.md` (rejected for product requirements — one file does not scale to thousands
of per-requirement records; it stays the PLATFORM loose-ends tracker); a separate KNOWN-GAPS.md
(rejected — the flag belongs AT the requirement it qualifies, or it rots). **Why:** the specs are
already "always master" with incompleteness rendered (oracle-fleet rule 10: 🚧 WIP = spec ahead of
code); ⚑ gap is its dual (code behind spec). The coordinator token already held `contents:write` —
this ADR is the missing POLICY, not a permission change. **Consequences:** W2+ (coordinator
pushing fixes/seeds directly) remains undesigned and needs its own ADR; the reviewer treats a
⚑-flagged shortfall as already-arbitrated (no re-litigation); FU-059 narrows to the W2+ question.

### ADR-087 — FU-018 credential injection: opaque refs + egress proxy (LLM) and a git-cred broker (GitHub)
**Status:** Accepted (2026-07-10; staged rollout, opt-in first). **Decision:** worker pods stop
holding real credentials; both credential classes resolve at the egress boundary, per leg:
**(A) OpenRouter** — the operator labels session Secrets (`openrouter.teststuff.net/session-key`),
the launcher sets `OPENROUTER_API_KEY` to an opaque reference `ref:<ns>/<secret>` (worthless
outside the cluster), and the egress proxy resolves ref→key via the K8s API (honoring ONLY
labeled session secrets — the label check stops the proxy being a generic secret oracle), caches
~60s (revocation latency), and injects the real key into the upstream Authorization header. Proxy
RBAC = get-secrets Role per PROJECT namespace (rendered from stacks.json; the AgentStack XRD owns
it later), never cluster-wide. **(B) GitHub** — git speaks TLS directly to github.com, so header
injection can't work; instead a `git-cred-broker` (agent-egress, ConfigMap-python like the proxy)
mints a fresh ~1h installation token per request via the `agents-github-app` key (Infisical→ESO),
scoped to the single requested repo (allowlist = stacks.json), reachable only from worker pods
(NetworkPolicy, the FU-020 counterpart); the agent-base credential helper / gh wrapper call it at
use time — freshly minted per operation ⇒ run duration becomes unbounded by token TTL, retiring
the FU-064b volume-mount interim. **Rollout:** `AGENT_CRED_INJECT=1` opt-in per dispatch →
acceptance rounds on the live oracle queue → default-on → drop the env/mount fallbacks with
FU-020's deny-all. **Considered:** TLS-intercepting proxy for github.com (rejected — MITM CA in
every pod, brittle); pod ServiceAccount tokens as caller identity for the broker (deferred to v2 —
NetworkPolicy + single-repo scoping bounds v1 blast radius); dual-writing session keys into
agent-egress (rejected — two sources of truth). **Why:** three TTL/credential walls in one day of
measured runs (TICK-LOG meta-2); FU-066's subscription token must NEVER sit in a worker pod.
**Consequences:** the proxy becomes stateful-ish (secret cache) and RBAC-bearing; reviewer/
coordinator keep their ESO tokens (scope = workers first); FU-064b marked interim-superseded once
default-on; FU-066 unblocks after acceptance.

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

### ADR-070 — Local caching tier (images / nix / apt): images leg resolved → ADR-091
**Status:** Superseded for images (2026-07-14, ADR-091); nix leg resolved 2026-06; **apt leg
still open** (no pain yet). **Original decision (images/apt):** none — leaning to an
out-of-cluster, always-on LAN box running **Zot or Harbor** as a pull-through image cache
(consumed via Talos `registries.mirrors`), plus maybe apt-cacher-ng. **Considered:** Harbor,
Zot, `distribution/registry`, Spegel (in-cluster P2P), Squid (rejected). _Update:_ the **nix** leg
landed differently than the original "out-of-cluster" lean — an **in-cluster** pull-through cache
(nginx on a Longhorn PVC, ADR-083, `argocd/resources/nix-cache/`), acceptable because losing it on
a cluster wipe only costs a re-fill and its main consumer (agent pods) lives in-cluster anyway.
_The images leg followed the same shape_ (ADR-091: in-cluster `registry:3` pair, `registry-cache`
ns) — the out-of-cluster lean and the Harbor/zot weight both dropped.

---

_When a decision here changes, update the block (mark **Superseded** and add the new one) rather than
deleting history — the record is the point._

### ADR-088 — 192.168.0.0/16 partitioned by address class; VIPs never share a range with real hosts
**Status:** Accepted (2026-07-13, operator-directed). **Decision:** the full RFC1918 `/16` is
partitioned by *address class*, not chronology — the table lives in [`ip-plan.md`](ip-plan.md).
Load-bearing choices: `192.168.2.0/24` stays as-is (frozen map, no renumbering); **router-owned
HAProxy VIPs get their own `192.168.3.0/24`** where a real host may never exist (OPNsense carries
the alias, clients route via the gateway — validated live with the transcripts VIP; last octet
mirrors the backend cluster VIP); **cluster/BGP service space is `192.168.32.0/19`** (contains the
live `40.0/24` LBIPAM pool; per-stack /24 pools carved from it *when a stack actually needs
isolation* — not yet); IoT gets a `/22` (ESP32-per-actuator endgame < 1000 devices), wifi-VLAN
segments get per-VLAN /24s, `128.0/17` stays unallocated. **The rule that outlives the table:**
virtual IPs only from VIP blocks, real hosts only with an inventory entry first, `git grep` +
`nmap` before assigning. **Considered:** renumbering the LAN to a /20 (rejected — touches every
static host/Talos config for zero function); per-stack LB pools now (rejected — reserve the space,
defer the mechanism until a stack needs its own pool/policy). **Why:** VIPs interleaved with real
hosts produced two live ARP-shadowing collisions (transcripts VIP on the Matchbox LXC, infisical
VIP on the Docker host — 2026-07-13); physical scale is bounded (~10³, ARP/L2) while virtual scale
is not (routed), so they get differently-sized homes. **Consequences:** legacy `2.0/24` VIPs
migrate to `3.0/24` opportunistically (FU-071); new exposures land in `3.0/24`/`32.0/19` from day
one; the wifi-password→VLAN plan slots into the reserved VLAN blocks without touching the table.

### ADR-089 — Storage tiers with quota-as-contract: consumers get caps, the platform keeps promises
**Status:** Accepted (2026-07-13, operator-directed). **Decision:** Longhorn splits into three
tag-fenced tiers — **std** (the original small always-on disks; the DEFAULT class is fenced to
them via `persistence.defaultDiskSelector`), **bulk** (`longhorn-bulk`: wk-metal-01's 500G MX500
+ wk-02's 240G-grown virtual disk, 2 replicas across those zones), **fast** (Optane, unchanged) —
and capacity becomes a **claim-side contract**: the AgentStack claim's `spec.repos[].storage`
caps render as a per-namespace ResourceQuota (per-StorageClass `requests.storage`), and every
`garage_bucket` states `max_size`. The ADR-084 lens: consumers never think about disks — they
read the advertised tier ceilings (SERVICES.md), ask via their claim, and an over-cap PVC/PUT
fails fast with a legible error at CREATE time instead of wedging unschedulable in Longhorn.
The platform's side of the contract: over-provisioning stays 100% and granted caps stay within
real scheduling headroom (max − reserved − scheduled — NOT free bytes, the 2026-07-13 lesson).
**The fence is load-bearing:** Longhorn schedules onto the EMPTIEST disk and empty-selector
volumes match any disk, so an unfenced 450G bulk disk would attract every std replica — onto a
tainted, wipe-on-PXE, possibly-powered-off laptop. Longhorn system components tolerate the
`homelab.io/ephemeral` taint (replicas live there; app pods still can't). **Considered:** buying
disks (nothing spare); onboarding the second laptop (kept as the next increment); growing only
wk-02 (single-zone bulk = no redundancy). **Why:** the 150G Garage ask against a pool whose
every disk had 2–9G scheduling headroom; the MX500 was already racked and idle. **Consequences:**
bulk ≈150Gi grantable at 2 replicas (wk-02-side headroom bounds it); std stays tight (~10Gi new)
until more always-on disks join; wipe/power-off of wk-metal-01 degrades bulk volumes until
rebuild — acceptable by tier definition, alert via Longhorn robustness metrics; disk tags +
bulk-disk registration are node-CR patches (`scripts/longhorn-tag-disks.sh`), not tofu.
**Addendum (2026-08-07): three bulk zones, wk-02 moves to `std`, and the quota finally exists.**
`wk-metal-04` (477.6G, tainted kata node, onboarded two weeks *after* this ADR and never
revisited) joins **bulk** with 150Gi reserved — larger than wk-metal-01's 100Gi because
`/var/lib/longhorn` shares the Talos EPHEMERAL partition with the containerd+kata image store, and
wk-metal-01's image store measured **137.5G**, more than its whole reservation; the kubelet's
`nodefs` floor evicts PODS, so losing that race takes rides down. With a third bulk zone, **wk-02
leaves bulk for `std`** — its third tier change, each earlier one correct about the problem in
front of it (dual-tag → it won every placement, #94; bulk-only → std fell to two zones, hp-01 hit
105% and a 2Gi transcripts PVC could not place, #98). **Consequences:** bulk has **no always-on
member** — Garage's only two copies live on tainted wipe-on-PXE nodes. Accepted as an *upgrade*:
they are two independent physical disks in two independent boxes, whereas wk-02's disk is a thin
volume on a single consumer NVMe shared with three VMs, on a pool measured at **99.14%** the same
day (`storage-ledger.md` §"A third sum"). *Always-on ≠ durable.* Also: the `std` fence turned out
to apply only to PVCs created after it (14 legacy volumes had an empty `diskSelector`, one of them
Garage's metadata sitting on the bulk laptop) — backfilled; and **`spec.repos[].storage` had never
been set by any claim**, so the quota-as-contract half of this ADR was decorative until now.
**Addendum (2026-07-16, FU-081):** a fourth tier `longhorn-scratch` — replica=1 on the bulk
disks, for per-ride throwaway volumes (the docker-mode dind `/var/lib/docker` ephemeral BLOCK
PVC). Same fence, no redundancy by definition: losing the replica kills a ride that dies with
it anyway. Claim knob: `storage.scratch`.

### ADR-090 — Full-LAN remote access: WireGuard on OPNsense (road-warrior), not Cloudflare Zero-Trust
**Status:** Accepted (2026-07-14). **Decision:** "work from the summer home like at home" = a
WireGuard instance ON the router (OPNsense core), road-warrior peers (laptop + phone only), split
tunnel routing `192.168.0.0/16` with Unbound as client DNS — so LAN names, HAProxy VIPs and the
BGP service VIPs (`32.0/19`, natively routable per ADR-046) all work exactly as at home. All as
code: `ansible/opnsense-wireguard.yml` (instance, peers, WAN + wireguard-group firewall rules via
the firewall-automation API, Unbound ACL), peers listed pubkey-only in `group_vars`.
**Considered:** Cloudflare WARP→Tunnel private network (rejected: every packet to the own house
hairpins through the CF edge, proprietary client + Zero-Trust enrollment, and the useful knobs
were already found Enterprise-gated in ADR-051 — violates local-first for the *private* tier);
Tailscale/Headscale (rejected: NAT-traversal SaaS/extra coordination service solves a problem we
verified we don't have). **Why:** the WAN IP is genuinely public (WAN iface IP == egress IP,
checked 2026-07-14 — **no CGNAT**), the router is already config-as-code, and ADR-050 scoped the
Tunnel as the *per-app public* edge with WireGuard explicitly "replaceable" for the private tier.
**Consequences:** `192.168.64.0/24` carved from the routed-virtual overflow block (ip-plan);
server privkey generated on and never leaves the router; peer privkeys only in wallet + device
(`scripts/wireguard-client.sh` renders configs/QR); endpoint `wg.teststuff.net` is a DNS-only
record whose *content* is out-of-band (dynamic Telia lease → FU-075: static-IP fee vs ddclient);
LAN-side Noise handshake E2E-verified (`scripts/wireguard-handshake-probe.py`); from-outside
verification pending (phone on LTE). Port 51820/udp — Telia's port filtering (53/25) doesn't touch it.

### ADR-091 — OCI pull-through mirrors: in-cluster registry:3 pair, not Harbor/zot
**Status:** Accepted (2026-07-14). Resolves the **images leg of ADR-070** (the nix leg's
precedent applied). **Decision:** pull-through OCI mirrors as an in-cluster platform service
(`registry-cache` ns, `argocd/resources/registry-cache/`, raw manifests per ADR-083): **one
`registry:3` (distribution) instance per upstream** — `mirror-docker-io` and `mirror-ghcr` —
because proxy mode is single-upstream by design. Cache PVCs on **longhorn-bulk** (re-warmable;
TTL-evicted, `REGISTRY_PROXY_TTL=168h`), **BGP LoadBalancer VIPs** `192.168.40.20/.21` — routed
VIPs are reachable from kata microVM guests where ClusterIPs black-hole (FU-072), and the same
stable IPs serve off-cluster consumers (ci-runner-01, laptops). Consumers wired at birth:
docker-mode agent rides (dind `registry-mirrors`, `agents/agent-session.sh`) and the
`REGISTRY_MIRROR_DOCKER_IO`/`REGISTRY_MIRROR_GHCR` env contract for k3d/kind CI-gate scripts;
the agentstack egress Composition **dropped the docker.io FQDNs** the same day (mirror down ⇒
pulls drop loudly and `AgentWorkerEgressDropped` names it — no silent internet fallback, that's
the point). **Considered:** **Harbor** (multi-upstream proxy projects, UI, Trivy scanning,
quotas, replication — rejected: core+portal+jobservice+registry+redis+postgres for what nginx-
grade simplicity covers, and its real added value serves *first-party hosting*, which ghcr owns
by decision (CI two-tier, ADR-082); revisit only if SLSA Phase-3 self-hosting moves artifacts
in-house); **zot** (single CNCF binary, but its sync extension is periodic/config-heavy where
dist's proxy mode is the purpose-built primitive); **Spegel** (P2P re-serving of node-cached
images — complements node pulls someday, useless for inner-docker/VM consumers or cold pulls);
**out-of-cluster box** (ADR-070's original lean — dropped like the nix leg: losing an in-cluster
cache costs a re-fill, and no new always-on host). **Consequences:** docker.io CI-gate pulls are
LAN-speed (alpine cold 2s / warm 1s from a kata ride, E2E 2026-07-14); dockerd's
`registry-mirrors` is Hub-only so dind's own ghcr pulls (k3d-proxy/tools) keep the `ghcr.io`
FQDN until gate configs route ghcr per-tool; **Talos node-level `machine.registries.mirrors` +
ci-runner-01 + ARC wiring deferred** (FU-073 carries the remainder). Gotcha for every future
VIP-consuming netpol: pod→LB-VIP flows are policy-evaluated **post-DNAT against the backend
identity** (Hubble-verified, even from kata) — allow with `toEndpoints`, not a VIP CIDR.
_Update 2026-08-30 (FU-196 v0):_ `mirror-ghcr` gains **optional upstream credentials**
(classic PAT `read:packages`, ESO-delivered, minted by `scripts/ghcr-mirror-pat-bootstrap.sh`)
— the original "anonymous works for all we consume" premise broke when the private oracle
corpus (~6GB) landed: Talos nodes already route ghcr through the mirror, but private pulls
fell back to ghcr directly (a 429 storm degraded the oracle-fleet#274 bring-up; a pod move
during a ghcr outage would degrade serving). **Accepted consequence:** packages the credential
can read become LAN-readable unauthenticated through the cache — scope it with a machine user
granted per-package read (the mint script prints both routes). ghcr TTL 168h→720h (corpus-class
re-pulls cost what a wipe costs). Policy-retention ("keep 2 latest prod releases") remains
inexpressible in a pull-through cache — that is FU-196 v1 (hosted registry), not this update.

### ADR-092 — Per-stack subdomain delegation: `*.<stack>.teststuff.net` → an in-cluster gateway
**Status:** Accepted (2026-07-15). Executes the **HTTPS-names leg of FU-039** (the "homelab as
AWS/Civo" self-service gap). **Problem:** every LAN HTTPS name is a *platform* change — one cert +
one `192.168.3.0/24` VIP + an HAProxy server/backend/frontend + an Unbound A-record, all hand-listed
in `ansible/group_vars/opnsense.yml`, applied by an operator, with a manual cert-sign in between. A
stack (e.g. **oracle**) cannot add a hostname without a homelab PR. A **wildcard cert is necessary
but not sufficient** to fix this: the cert is the cheapest part; the friction is the per-name
VIP/HAProxy/DNS. **Decision:** push per-name host-routing **into the cluster**. Homelab wires an
opted-in stack **once** — a `*.<stack>.teststuff.net` wildcard cert (LE DNS-01/Cloudflare, the
`homelab-acme-dns` token already has zone-wide DNS-write), one `3.0/24` VIP, one *dumb* wildcard-TLS
HAProxy frontend whose default backend is the stack's in-cluster **Cilium Gateway API** gateway, and
one **wildcard** Unbound override (`*.<stack>` → the VIP; hostname `*` API-verified 2026-07-15). The
stack then owns every hostname under its subdomain via **HTTPRoutes in its own `-iac` repo** — adding
`specs.oracle`, `api.oracle`, … is a PR there, **zero homelab change**. This slots into the ADR-084
three-layer topology (platform wires the wildcard + GatewayClass; the stack's `-iac` repo owns the
Gateway + HTTPRoutes; the app repo stays platform-agnostic) and the ADR-085 mechanism/policy split.

**TLS terminates at OPNsense HAProxy** with the wildcard cert (no cert-manager): HAProxy forwards
plain HTTP to the gateway's `:80` listener; the gateway host-routes by the preserved `Host`. **Opt-in:
** a stack that exposes no LAN service wires nothing (`stack_gateways` empty). Enabling it is still a
thin homelab PR *once per stack* (not per name) — the ADR-085 XRD path (make opt-in a stack-`iac`
claim) is the later trajectory, not this change. **First consumer — oracle:** the spec site moves
`oracle-specs.teststuff.net` → `specs.oracle.teststuff.net`, served through the gateway; an HTTPRoute
`URLRewrite` rewrites the `Host` back to `oracle-specs.teststuff.net` so the **Garage bucket alias
stays `oracle-specs`** (no destroy/recreate, no re-publish, no oracle-fleet change) — Garage still
sees `alias == Host`, honouring the garage.md convention where it matters (at the origin). The
cross-namespace ref (oracle-fleet HTTPRoute → `garage-s3` Service in ns garage) is granted by a
platform-owned **ReferenceGrant** in ns garage. VIPs: gateway cluster VIP **40.22** (40.20/.21 =
registry mirrors, ADR-091) ↔ HAProxy **3.22**; bgp advertisement keys off the Service label
`bgp=advertise`, carried via the Gateway's `spec.infrastructure.labels`. Folds in **FU-078** (the
opnsense-acme role now signs + polls a fresh cert to `statusCode==200` before HAProxy binds it — the
wildcard is issued through that same role, so the fix de-risks the rollout).

**Prerequisites (live):** Gateway API **v1.4.1** standard CRDs (`argocd/platform/gateway-api-crds.yaml`,
GitOps) installed **before** flipping `gatewayAPI.enabled=true` in `tofu/cilium.tf` (needs
`kubeProxyReplacement=true`, already set) — a live-cluster CNI reconcile, plan-and-review first.
The CRD app uses the **experimental** channel: we don't use TLS passthrough (TLS ends at HAProxy),
but Cilium 1.19's gateway controller *watches* `TLSRoute` and errors if that CRD is absent (verified
live), and flipping `gatewayAPI` needs a cilium-operator restart to load the config. **Considered:** wildcard cert
with routing still central (rejected — nicer naming but no self-service, each name still edits
homelab); in-cluster **cert-manager** termination (rejected for now — a new moving part; the existing
OPNsense ACME path already issues the wildcard; revisit only for public exposure); an ingress-nginx
controller (rejected — Cilium already the CNI, Gateway API is native, no second dataplane); renaming
the Garage bucket to `specs.oracle` (rejected — cross-repo churn + destroy/recreate + re-publish for
no gain over the `Host` rewrite). **Consequences:** a stack's browser surfaces become self-service
(the FU-039 direction, now real for HTTPS names); the platform gains Gateway API as a reusable
capability (any stack, and future in-cluster L7 routing); one more live cutover with the documented
`3.0/24` VIP-flush caveat (a `vip_settings/reconfigure` black-holes all `40.x` VIPs ~25 min — recovery
is a real FRR stop→start). Open verification carried into rollout: Cilium propagating
`infrastructure.labels` to the gateway Service (else the VIP won't BGP-advertise) and `URLRewrite`
hostname support. Full design + rollout: [`follow-ups.md`](follow-ups.md) FU-039; runbook recipe
"delegate a stack subdomain".

### ADR-093 — Argo Workflows + Events as the platform orchestration engine; agent-loop first
**Status:** Accepted (2026-07-17). This
is the "**open homelab ADR**" the oracle-fleet `ING-RT-STEP-CONTRACTS` spec defers its step engine
to, and it discharges **FU-026** (graduate the coordinator off the hand-driven CronJob+bash
substrate onto a durable engine). Operator also confirmed the FU-080 **`<stack>-agents`** namespace
direction (agent loop in `<stack>-agents`, ingestion DAGs in the stack workload ns). **Problem:** two independent consumers need the *same* thing — a
platform-provided step/orchestration engine with scheduling, cross-run retries, event-triggering,
and observability — and the platform has none, so both would otherwise hand-roll it. (1) The **agent
loop**: today's reflexes are k8s **CronJobs** in ns `agent-coordinator` (`review`/`coordinator`/
`model-scout`/`ledger`), `*/5` **blind polling** — the review reflex lists PRs across ~9 repos via
`gh pr list --json` (GraphQL) every tick whether or not there's work, which both adds up-to-5-min
latency and burned the coordinator-git installation's 5000/hr GraphQL pool to 9 during a manual
over-fire (FU-084 incident, 2026-07-17). (2) **Stack production DAGs** (oracle ingestion): the spec
already designs ingestion as `snapshot → parse → build → publish` + a scheduled `delta` job +
a quarterly `reconcile`, with **container-per-step, artifacts handed off via Garage/S3 (never shared
disk), each step idempotent and re-runnable** — and `ING-RT-STEP-CONTRACTS` *forbids* the app repo
from writing "orchestration, monitoring, or download-plumbing frameworks." So the platform MUST
supply the engine.

**Decision:** adopt **Argo Workflows + Argo Events** as THE platform orchestration engine (ArgoCD
apps under `argocd/platform/`, ADR-083 packaging discipline; **Garage as the S3 artifact
repository**, reusing the store we already run). Argo's native model — container-per-step, S3
artifact passing, idempotent re-runnable steps, CronWorkflow scheduling, Sensor event-triggering —
is a near-drop-in for the ingestion contract, and the reflex loop maps onto CronWorkflow + Sensor
with the **LLM judgment living *inside* steps** (the coordinator/reviewer run as pod steps; Argo owns
*when/retry/observe/trigger*, never the LLM's decisions — Argo is a scheduler+DAG, not Temporal-style
durable-execution of the model's reasoning).

**Rollout is agent-loop-FIRST, phased** (operator call 2026-07-17, reversing the drafter's
oracle-first lean): oracle ingestion is **unbuilt** (only `snapshot` is spec'd; parse/build/publish
deferred) and its first step is a **42GB download** — the worst possible first-attempt/retry loop for
a platform bring-up (two unknowns at once, slowest feedback). The agent loop is the **most mature,
cheapest-to-iterate** workload, and Argo Events is the direct fix for the FU-084 poll/GraphQL pain.
- **Phase 1 — agent loop** (validates the CONTROL PLANE: Workflows + Events + EventBus + CronWorkflow
  + Sensor + pod-steps). First target = **review-reflex → CronWorkflow + Events Sensor**: the worker's
  `agent-finalize` POSTs an **in-cluster** "PR green, review it" event to the EventBus when it opens
  an armed green PR → a Sensor fires the review WorkflowTemplate — the ADR-084 `sync.yaml` deploy-
  webhook trick, generalized (event-driven, near-instant, and the reflex lists PRs only on a real
  event instead of blindly every 5 min). The `*/5` cron stays as a thin **calendar-EventSource
  backstop** for anything the edge missed. Then coordinator/scout/ledger port as trivial CronWorkflows.
- **Phase 2 — ingestion** (when oracle builds it): the snapshot/delta/reconcile DAGs on the by-then-
  boring Argo, which is where the **artifact-passing path** (Garage as artifact repo, resume-from-
  completed-parts, big-file handoff) gets validated. Phase 1 deliberately does NOT exercise that path
  — do not declare "Argo proven" and skip artifact validation when ingestion lands.

**Safety / rollback:** the reflexes are **idempotent + level-triggered**, so the Argo CronWorkflow runs
**alongside** the existing CronJob during bring-up (idempotency keys `(issue, base-sha, round)` + the
K-cap dedup double-dispatch), and a botched Argo path flips back to the CronJob in one `kubectl` — no
window where a broken migration stalls the platform. The EventBus (NATS JetStream StatefulSet) and both
controllers get **resource requests** at birth (FU-082 discipline — a stateful bus must never be
BestEffort). Per-namespace `workflow-controller` RBAC is rendered by the **AgentStack Composition**,
dovetailing FU-080's `<stack>-agents` namespace direction (ingestion DAGs run in the stack workload ns,
the agent loop in `<stack>-agents`).

**Considered:** **Temporal** — heavier (its own datastore + frontend/history/matching/worker services)
and its model is SDK code-workflows, a poor fit to the container-per-step-with-S3-handoff contract that
is Argo's native shape; rejected on weight + fit + it isn't declarative-YAML-from-git the way a
CronWorkflow is. **Bespoke CRD + controller** — lightest to run, heaviest to build/maintain, reinvents
scheduling/retry/observability/UI Argo ships; rejected as exactly the wheel-reinvention FU-026 exists to
avoid. **Stay on CronJob/Job + bash glue** — fine for today's trivial reflexes, but ING-RT-STEP-CONTRACTS
forbids the app repo from carrying orchestration, so hand-rolling per-stack CronJob-chain glue (S3
handoff + retry bookkeeping + per-step metrics) builds a bespoke orchestrator AND leaves FU-026 to build
a *second* one — two substrates, a costlier double-migration later; rejected on "reinvent twice."
**oracle-ingestion as the first consumer** — rejected (see rollout: unbuilt + 42GB). **GitHub-delivered
webhook** as the review event source — rejected: argo-server/event webhook is LAN-only and GitHub can't
reach in (same reason ADR-084 POSTs from an in-cluster runner); the worker POSTs the event locally.

**Consequences:** a new **stateful** platform dependency (JetStream EventBus) — operational surface +
upgrades + the requests above; mitigated by parallel-run rollback. FU-026 is discharged by Phase 1 and
the ingestion "open ADR" is resolved even though ingestion builds later. The review reflex drops from
blind `*/5` GraphQL polling to event-driven, cutting both latency and the GraphQL burn behind FU-084
(pairs with FU-084's rate-limit *alerting* — the metric watches it, this removes the biggest burner).
Argo's Prometheus metrics (workflow/step duration, phase, retries) land in the existing kube-prometheus
stack and the argo-server UI gives DAG/step visibility "for free"; the **agent-domain** metrics (cost,
model-health ledger, transcripts, the PR-state stall detector) stay on the github-exporter/pushgateway/
OTLP rails — Argo adds *orchestration* observability, it does **not** replace the domain layer, and both
keep feeding the shared Grafana (don't fragment observability into the per-stack namespaces — run the
*compute* per-namespace, keep the *metrics/transcripts* centralized, labelled by stack). Relates
**FU-026** (discharged), **FU-050** (coordinator reflex ports here), **FU-080** (per-namespace RBAC),
**FU-084** (the incident motivating the edge-trigger), **ADR-084** (the in-cluster-webhook precedent),
**ADR-085** (mechanism/policy split — Argo is platform mechanism, the WorkflowTemplates/DAGs are stack
policy), and oracle-fleet `specs/ingestion` `ING-RT-STEP-CONTRACTS`. Weighed against CONTEXT: declarative
from git (CronWorkflow/WorkflowTemplate/Sensor YAML, GitOps-synced ✓), open-source/replaceable (Argo is
CNCF; the artifact repo is our own Garage ✓), local-first (no orchestration SaaS ✓), budget-conscious
(self-hosted, reuses Garage; the cost is the sized EventBus footprint ✓).

### ADR-094 — Item-scoped coordinator dispatch: the scan schedules, the LLM judges
**Status:** Proposed (2026-07-17; drafted at operator direction after the FU-080/FU-085 review and
the oracle-stack parallelism stress-test — accept on operator read-through). **Problem:** the
coordinator is the last scope-scoped LLM role. `coordinator-scan.sh` computes the actionable set
deterministically, then **discards item identity** and spawns a whole-stack tick whose TICK_PROMPT
says "pick the single highest-priority item" — selection, a scheduling concern with no judgment
content, is delegated to the LLM. Downstream symptoms: one action per tick; lane parallelism
throttled at cron cadence; "per-track coordinators" would be scope-partitioning re-invented a
third time (global → per-stack FU-080 → per-track TRACKS seed); and every real constraint the
oracle stress-test surfaced — the TRACKS ≤1-open-PR-per-lane rule, repo dispatchability
(context-only `oracle-iac`, the deliberate FU-052-frame exclusion), the shared subscription-session
ceiling (found by dying on it, 2026-07-12), inter-issue dependencies living as prose the tick must
"learn by reading bodies carefully" — is carried as prompt text instead of enforceable code. The
**reviewer is the counter-model**: a deterministic predicate decides *what/when*,
`reviewer-session.sh <repo> <PR>` judges *one item* — which is why the review path parallelized and
edge-triggered trivially and needed no per-stack/per-track story. The platform's history is one
long migration of decisions out of the LLM (FU-045 wake gate, FU-080 whether-per-stack, ADR-093
"Argo owns when/retry/observe/trigger, never the LLM's decisions"); item selection is the last one
still inside.

**Decision:** invert the hot path. (1) **The scan emits work units** — each existing predicate
clause IS an action class: `(repo, item, clause)`, clause ∈ queued-dispatch | C4/C5 re-dispatch |
changes-requested round | un-armed major | merge-conflict | arbitrate. (2) **The coordinator
session gains an item mode** (`coordinator-session.sh --item`): seeded with exactly one unit,
prompt = "reconcile THIS item; if it is no longer actionable on re-read, exit clean" — doorbell
semantics at item level, idempotent under at-least-once delivery. Triage (issue self-containment +
platform facts), budget sizing, and exception arbitration stay inside the item session — judgment
*about one item* was always the coordinator's real value. (3) **Every scheduling constraint
becomes a scan predicate** — dispatch a unit iff: lane free (`track/*` labels, ≤1 unit in flight
per lane — the track label is the human-declared independence assertion, so the scheduler needs no
judgment) ∧ deps closed (`Depends-on:` body lines, FU-087) ∧ repo dispatchable (the AgentStack
claim carries a fixer block — context-only repos become a visible predicate, not an implicit
clone-but-can't-work state) ∧ capacity available (FU-088: global subscription-session semaphore +
OpenRouter credit gate). (4) **Board-level judgment survives as a rare janitor tick** (~daily,
report-only: direction-change sweeps, orphan classes, cross-PR smells) — deliberately not the hot
path. (5) **Parallelism is a latent property, not the goal**: the current chassis-track backlog is
serial by shape (shared files), so the near-term payoff is constraints-as-code; throughput arrives
free when the backlog's shape allows it.

**Considered:** multi-dispatch TICK_PROMPT ("reconcile every actionable item, ≤1 per free lane") —
prompt-level parallelism that keeps selection in the LLM and its constraints as drift-prone prose;
rejected, and explicitly *skipped* as an interim (the item mode obsoletes it). **Per-track
coordinator sessions** (the TRACKS seed) — dissolves into "the item executor filtered by lane".
**GitHub Projects / native sub-issues as the dependency source** — extra GraphQL surface, cross-repo
edges into context-only repos, and the scan must read ONE canonical greppable source; native
relations stay an optional UI mirror. **Keeping the free-choice tick for safety-net breadth** —
retained, demoted to the janitor cadence.

**Consequences:** the scan becomes the single point of liveness — a clause bug silently starves an
item class where a browsing LLM might have noticed; the mitigations already exist and stay (the
level-triggered cron sweep, report-only orphan/`⏳ queued-blocked` lines, the `agent/error`
breaker, the exporter stall detector). Item-parallel sessions multiply concurrent subscription
burn — the FU-088 semaphore is a **prerequisite** for lifting WIP above 1. FU-080's remaining leg
loses all scheduling semantics (pure isolation: identity, RBAC, creds ref-rail, namespace).
FU-085 compounds: an event is already item-shaped, so the edge path submits an item unit directly
and the cron sweep emits only the units the edge missed. Builds: **FU-086** (units + item mode),
**FU-087** (`Depends-on`), **FU-088** (capacity semaphores). Relates FU-045/FU-050/FU-052/FU-080/
FU-085, ADR-093, oracle-fleet `specs/TRACKS.md`.

### ADR-095 — ghcr pushes happen only in Actions; in-cluster workloads never hold GitHub credentials

**Accepted 2026-07-24.** Found via the corpus pipeline: its publish step assembled the OCI
archive in-cluster and needed a registry credential to push. Structural facts: fine-grained PATs
cannot carry the packages scope; an in-cluster pusher therefore needs a broad classic PAT
(`write:packages` = the whole org's packages) parked in a workload namespace, manually rotated —
while every Actions workflow has repo-scoped, auto-rotated `packages: write` via `GITHUB_TOKEN`
for free (the rail ADR-084 deploys and every platform image already ride).

**Decision:** the boundary is the plane, not the credential. In-cluster steps build artifacts
**into Garage by reference** and stop; thin *release* workflows on the ARC runner (LAN to
Garage) fetch, digest-verify, and promote to ghcr with `GITHUB_TOKEN`. Release workflows read
Garage with an EXISTING stack reader key delivered as repo Actions secrets — set imperatively
from the cluster-minted connection secret (the value's source of truth stays the cluster;
tofu/github would give it a second home — docs/github-setup.md §ghcr has the rotation recipe).
First instance: oracle-fleet `release-corpus.yaml` (fleet hosts it, not oracle-iac: the
`GITHUB_TOKEN` package grant is repo-scoped and the artifact's contract lives in fleet's spec —
producer = iac policy, promoter = the repo that owns the package). Relates ADR-082, ADR-084,
ING-RT-PUBLISH.

### ADR-096 — The egress proxy becomes the model/billing router (FU-095: decision API + budgeter)

**Accepted 2026-07-27.** Model choice is a static per-stack chain (`agents/stacks.json`) walked by
the LLM coordinator over `AGENT_STRIKE` issue comments; capacity is three scattered gates (proxy
`/anthropic-limit`, `subscription-latch.sh` kubectl semaphore, `agent-session.sh` credit floor);
strikes/provider-health have no queryable store; per-project OpenRouter headroom is invisible; and
there is no cross-rail move ("subscription ≥80% deferred + OpenRouter budget available → route
there"). The FU-095 buy-vs-build survey settled BUILD: external gateways (LiteLLM/Portkey) would
un-solve the proxy's subscription gate + cred/pin injection; per-prompt routers can't read our
ledger.

**Decision:** evolve the ADR-081 egress proxy (`argocd/resources/openrouter-proxy/`, ns
`agent-egress`) into the router — it already carries every dollar of both rails, holds the
subscription window state, resolves `ref:` creds (ADR-087), computes provider pins, and observes
provider failures passively in the data plane. It gains: **(1)** a launcher-called decision API
(`POST /route` — never the LLM, ADR-094; the launcher passes the chain it knows, the router
filters/orders it against strikes + provider health + class policy + capacity, and answers either a
dispatch {rail, model, pin, cap} or an **explicit typed defer** {zero-capacity | subscription-limited
| openrouter-budget-exhausted | credit-floor | chain-exhausted, retry_after}; only chain-exhausted
escalates — M1 doctrine); **(2)** a durable store — sqlite3 (stdlib) on a 1Gi Longhorn PVC
(`strikes`, `provider_events`, `rotation`, `run_reports`, `decisions`, `budget_anchors`,
`latch_state` — the 429 latch survives restarts; `:memory:` fail-open fallback, an empty DB never
blocks dispatch); **(3)** budgeter authority — the FU-088 gate absorbed, FU-109 per-consumer tiers
(`dispatch` 0.90 / `heavy` 0.80), the semaphore moved server-side, and per-project OpenRouter
headroom read live from `GET /api/v1/auth/key` (probed 2026-07-27: `limit`, `limit_reset: weekly`,
`limit_remaining`, `usage_weekly`) via the standing `<project>-openrouter` key refs. Budget policy
stays claim-owned: **`project.budgetUSD` becomes the mandatory AgentStack ceiling** (= optional
fixer + reviewer + coordinator sub-budgets; the standing key's limit enforces the ceiling at
OpenRouter, the router enforces role splits from its `run_reports` attribution). Class policy
(`model-classes.json`, router-owned in the kustomize dir): audit/research get reasoning tier +
dual-model + the `openrouter/fusion` chain head (M6), reviewers get `min_tier ≥ author`
(decorrelation), coding keeps the worker bar. Cross-rail v1 is chain-entry eligibility for
harness-flexible roles (a `claude/*` entry needs a clear tiered subscription verdict; an OpenRouter
entry needs project headroom + credit floor); claude-harness OAuth sessions stay subscription-only.
Rollout: observe-only → shadow (`AGENT_ROUTER=shadow`, ≥1 week) → authoritative for workers
(coordinator stops passing `--model`; explicit `--model` still wins; `/route` unreachable falls
back to today's static chain + latch).

**Considered:** a separate control-plane service (duplicates subscription/pin/cred state the proxy
already holds); LiteLLM/Portkey/OpenRouter presets (the FU-095 survey — gateway mechanics or
click-ops); CNPG for the store (needs psycopg → breaks the stdlib/stock-image ConfigMap-script
pattern); router reads stacks.json itself (rejected: launcher passes the chain — keeps
cluster-wins claim semantics in one consumer); scraping a rotation ranking (probed 2026-07-27:
**no rankings API exists** — `order=top-weekly` is ignored by `/api/v1/models`, frontend paths
serve the app shell → the rotation is a git-curated `rotation_fallback` list fed by the scout
digest, staleness-alerted).

**Consequences:** the proxy becomes single-replica stateful (`strategy: Recreate`, ~10–20s
data-plane blackout per script roll — launchers already fail-open/retry). Two strike stores during
transition (GitHub comments stay the human/audit trail, one write path dual-writes). The router
owns billing/subscription knowledge: decisions/deferrals/budget gauges on `/metrics`, a new
`agent-router` dashboard, alerts RouterZeroCapacity + OpenRouterProjectBudgetLow +
RouterRotationStale + RouterDbEphemeral (capacity states `triage: none`). Builds FU-095(a),
absorbs FU-109. Relates ADR-081, ADR-087, ADR-094, FU-057, FU-088 (archived), model-routing.md
(§M8 = the router).

**Addendum (same day, operator direction):** cost knowledge is GROUND TRUTH, not estimates —
the data plane harvests each forwarded completion's generation id and a daemon thread fetches
`GET /api/v1/generation?id=` with the same session key (probed: `total_cost` = the billed
figure, `provider_name`/`model` = what actually SERVED — the M5 attribution — and
`native_tokens_cached` measures the real cache hit behind the pin math's h=0.8). Rows land in
`generations` (90d); series `router_generation_cost_usd_total{model,provider}` +
`router_observed_cache_hit{model}`. The account-wide `/api/v1/activity` API is management-key
-only — rejected (the proxy holds no management credential by design). And the /route ordering
rule within a class: **effective-cheapest wins with a small jitter band** (uniform pick among
candidates within ~15% of the cheapest — exploration keeps evidence accruing across near-priced
models; `model-classes.json` `selection`).

**Addendum 2 (same day): market pricing + the MCP rankings feed.** The pin's price basis is now
the **market effective price** — the model page's "Effective Pricing" data
(`GET /api/frontend/v1/stats/effective-pricing?permaslug=<dated>`, found 2026-07-27: per-provider
30d traffic-weighted `effectiveInputPrice` + REAL `cacheHitRate` + token share; the dated
permaslug rides in every `/endpoints` entry's `name`). `compute_pin` (proxy) and
`pinned_provider(market=)` (estimate_budget.py — twins kept in step) price each provider by its
market row when one exists, list-blend at h=0.8 otherwise; pins report `basis: market|list`
(verified live: deepseek-v4-flash pin flipped to DeepSeek @ $0.033/M measured, 78% real cache
rate). This supersedes the assumed-h blend as primary and is the /route class-ordering price
source (harvested generations validate it; registry blend = cold-start fallback). **Rotation
un-dead:** OpenRouter's DOCUMENTED MCP server (`mcp.openrouter.ai/mcp`) accepts a standard API
key (probed — no OAuth dance) and `list-daily-model-rankings` returns daily model popularity by
token volume — the router pulls it dailyish via `ROUTER_ACCOUNT_REF` into the rotation store
(source `openrouter-daily-rankings`, top-30), superseding the git-curated `rotation_fallback` as
primary (the fallback list stays as the belt). Also noted for P3: OpenRouter's `pareto-router`
request plugin (`price_source: weighted_avg`, server-side Pareto frontier over coding models) —
a candidate serverside twin of our class ordering, parked until API manageability is clear.

**Addendum 3 (2026-07-31, operator session — the #48/#71 saga postmortem fed back).** Querying the
live router store (`provider_events`: 1753 observations over the exact saga window 2026-07-27
18:57 → 07-29 07:43 UTC) turned "provider reliability" from abstraction into evidence and surfaced
one net-new mechanism the design lacked.

**The evidence (per-model outcome over the window):** `deepseek-v4-flash` 100% ok (n=545),
`tencent/hy3` 100% (n=111), `ling-3.0-flash:free` **97%** (n=207) — versus `laguna-s-2.1:free`
33% ok / **53% 401** (n=263) and `laguna-s-2.1` **paid 19% ok / 81% 429** (n=607). Two rulings:
**(1) free-vs-paid is the wrong axis** — a *free* model (`ling:free`, 97%) beat a *paid* one
(`laguna` paid, 19%); laguna is a bad **provider** at both tiers, wearing 401 (free) or 429 (paid).
Health + `/route` ordering key on observed **`(model, provider)` reliability, tier-agnostic**; the
`:free` string is never itself a demotion. Free models stay in-chain **deliberately, as cheap
instability canaries** (they flush infra bugs paid models mask) — `rotation.canary_verdict` is fed
from these aggregates, and a canary is only cheap if it fails in *seconds* (see the breaker below).
**(2) Passive `provider_events` is the PRIMARY health substrate, not `/report` strikes** — it
captured all 142 401s (140 = laguna:free) that the `/report` path **missed** (the `strikes` table
is empty: r2's `agent-finalize` crashed on `env: python3: not found`, so the finalize-dependent
write never ran). `/report` stays the audit twin.

**Net-new leg — the in-flight 4XX circuit-breaker (the router had none).** The 140 laguna:free
401s were ONE ride's goose continuation loop hammering a hopeless auth failure for ~20 min; the
proxy *observed* every one but never *acted*. New leg: the proxy counts 4XX per `(session, model)`
(it already holds the data) and at a **class-scoped threshold — auth (401/403) ~3-5, generic 4xx
~10; 429 → fail-over/back-off, never session-abort** — (a) **stops forwarding** (spares the
provider the other ~130 calls; also the "haywire agent spams OpenRouter" guard) and (b) emits
**`circuit-open`** for that session into the store.

**The killer is NOT the router (ADR-094 boundary) — reuse FU-021's watchdog, retuned.** FU-021
(archived 2026-07-12) already built the in-pod **storm watchdog** (agent-runtime#8/#11) +
`GOOSE_MAX_TURNS=200` belt for exactly this — but its trigger is ~200 turns / "200 auth failures in
21s", so the 140-401 storm ran *under* the bar. **Line item (agent-runtime): drop the watchdog
trigger ~200 → ~10 and drive it off the proxy's `circuit-open` signal** (the source-of-truth 4XX
count) rather than its own coarse in-pod counter. Proven killer, ~20× tighter, no pod-delete RBAC
added to the egress plane.

**Why NOT "rewrite the Nth 401 as a 500" (the tempting single-mechanism):** FU-021's root cause is
explicit — goose's storm is its *final-output continuation loop* and **no error class stops it**
(812× on a bad key); a 500-rewrite just becomes a 500-storm. A terminal-status rewrite only helps
harnesses that honor status classes — the **Anthropic SDK / claude harness** treats 400/401/403 as
non-retryable (fail-fast) but 500 as *retryable* (so 500 is the wrong pick there too). So a
status-rewrite is a **per-harness belt** (claude/opencode: a 4xx-non-429 at the circuit point;
goose: none), verified by a small probe matrix — never the primary kill.

**Also into the health model:** per-`(model, provider)` **429 backoff distinct from the account
429-latch** (FU-088) — laguna paid's 81% per-model 429 slipped straight through the
subscription-account-wide latch; a model at 81% 429 must be demoted by `/route` regardless of the
account latch. Rehab is **per-class TTL** — 401 sticky/long (an eligibility fact, not transient),
429 honors `retry-after`, generic 4xx medium. All of this builds under the **FU-095 router leg**
(the `/route` decision endpoint stays the gating build); the FU-021 watchdog retune is the one
out-of-band actionable (agent-runtime).

**Addendum 4 (2026-08-02): P3–P5 shipped, plus the cooldown/recovery leg (the end-state
resilience).** `POST /route` is live: class resolve (explicit > `label_map` > `role_defaults`),
candidates = the launcher-passed chain or — when none — **rotation-fed (P5)**: the
`model_tiers` universe ∩ daily-rankings order, broken canaries excluded, class `chain_head`
first; filters = claim `deny` + task-scoped strikes + cooldowns + class rails; within the
OpenRouter rail the **effective-cheapest wins with the 15% jitter pick** (price = the pin's
`eff_in`, market basis; free = $0 so free-first falls out of ordering, never a special case);
capacity gates per rail (tier verdict + semaphore / key headroom) yield **typed defers with
`retry_after_s`** — only `chain-exhausted` (deny/strike residue) escalates. Launcher seam (P4):
`agent-session.sh` consults /route before harness derivation — `AGENT_ROUTER=shadow` (default:
log + record, dispatch unchanged — the soak that gates the flip), `authoritative` (decision
replaces the model; explicit `--model` wins; a defer aborts the dispatch), `off`. **Net-new —
model cooldowns, the temporary-blacklist/recovery loop the operator specified** ("free model
429s → blacklisted temporarily → comes back → picked again"): ≥`min_events` in `window_s` with
≥`bad_share` non-2xx trips a hold (reason = dominant class: `429-burst`/`auth-burst`/`5xx-burst`;
per-class TTL split from addendum 3 = an open dial, v1 escalates uniformly), `base_s` doubling
per consecutive trip to `max_s`; **any 2xx clears + resets the streak**; an expired hold is
half-open — eligible again, cheapest ordering re-picks it, natural traffic is the probe
(`half_open` flagged in the decision). Cooldowns key on OUR passive events only: probed
2026-08-02, `/endpoints` now serves `uptime_last_5m`/`_1d`, but laguna measured 99.9–100%
upstream while our account saw 81% 429 / 53% 401 — upstream uptime is OpenRouter's routing
view, blind to per-account/tier limits; it stays the PIN layer's outage filter, never the
cooldown signal. (The OpenRouter frontend benchmarks endpoint is session-cookie-gated — API
key 401s — so the M8 capability prior starts as a curated snapshot; model-routing §M8.)
Surfaces: `router_decisions_total`, `router_cooldowns_active`, cooldowns + decisions in
`/router-status`. Verified: 11-check jail sim of the full
429→cooldown→paid-fallback→half-open-re-pick→2xx-clear→escalated-re-trip cycle through the
real data plane; live entry = the sleep free-first chain test (claim reorder, same date).

### ADR-097 — Dispatch parallelism keys on declared footprints, not track labels

**Accepted 2026-08-03.** Closes FU-086 knob 3's design question. **Decision:** per-repo worker
parallelism is bounded by **footprint intersection**: every agent issue declares its expected
write surface as a machine-readable `Touches:` body line (paths/globs), authored ONCE at issue
creation by the authoring LLM (FU-090 contract, [issue-authoring.md](agents/issue-authoring.md));
the deterministic scan holds a queued unit iff its declared footprint intersects any in-progress
issue's footprint ([workflow.md](agents/workflow.md) §Footprint hold). **An undeclared footprint
is exclusive** — it conflicts with everything, preserving WIP=1 semantics for legacy issues; the
scan raises `AGENT_WIP_LIMIT` per extra dispatch, capped repo-wide alongside the ≤3-open-PR
updater-churn bound (oracle-fleet TRACKS rule 1). `track/*` labels demote to reporting decor;
the TRACKS path table becomes documentation of ownership norms, not the scheduler's input.
**Considered:** per-lane label counting (the original knob 3 — rejected: hand-maintained
ownership tables drift, conflicts aren't always path-shaped, and oracle already granted lane
parallelism 2026-07-10 that the binary hold ignored); LLM-computed conflict sets at dispatch
time (rejected: ADR-094's line — scheduling stays deterministic prose-free bash; a per-tick
judgment re-opens the issue-96 burn class and downgrades miscounts from wasted-session to
same-lane double-dispatch); optimistic dispatch + arbitration (rejected: rebase churn is
O(open PRs × merges), priced by TRACKS rule 1). **Consequences:** ordering (native blockedBy,
FU-111) ∧ conflicts (footprints) ∧ burn (FU-088 semaphore) are all deterministic at dispatch;
judgment happens once, at authoring, where it is reviewable. A worker escaping its declared
footprint is the residual risk — the reviewer flags escapes (belt, FU-086). Builds: FU-086.

**Addendum — `agents/replay/**` exempt (2026-08-18, the FU-167/FU-168 joint call, operator-ruled).**
The replay tree is stripped from footprint semantics on both sides: declared entries under it
create no intersection holds, and changed paths under it are never `Touches:` escapes (one
predicate — `fp_replay_exempt`, `agents/footprint.sh` — consumed by the scan hold and by
`touches-check.sh`, which the scan and the reviewer both source). **Why:** the ADR-103 ratchet
COMPELS a replay touch on every clause PR, so requiring its declaration was ceremony — it
manufactured the unsatisfiable-footprint class (homelab#270/PR#275) and a governance block on a
compelled edit (PR#547), against zero real replay conflicts measured over 41 PRs. Content safety
stays with the review rubric's worlds-are-extraordinary rule, the ratchet itself, and git blame.
**Considered:** per-family disjoint declarations (FU-167 move 5 still lands, for dedup/ownership
— but the ceremony would remain); an authoring-side lint enforcing the clause-file↔replay pairing
(unnecessary once nothing needs declaring — deliberately NOT built).
**Addendum 2 — the sibling compelled classes (2026-08-19, homelab#601, seat ruling under the
same rationale):** the exemption widens to the two OTHER files the gates themselves compel a
clause PR to touch — top-level `agents/*-test.sh`/`*-replay.sh` suite pins (a moved extracted
block compels the suite edit) and `docs/agents/*-fsm.{yaml,md}` (the model's `replay:`
declarations plus the regenerated view merge-path-lint reds when stale). Evidence: PR#599's
ride was compelled outside its `Touches:` by exactly these two, one day after the first
addendum. Depth-guarded — nested suite scripts (`agents/coordinator/*-test.sh`) and non-fsm
docs stay ordinary declared surfaces. One predicate (`fp_replay_exempt`), both consumers.
**Addendum 3 — source-side REPLAY sentinels, content-keyed (2026-08-26, homelab#944, seat
ruling under the same rationale):** the fourth compelled class cannot be path-keyed — the
harness extractor is sentinel-only, so pinning a block of ANY script compels planting
`# >>>REPLAY:<name>>>>`/`# <<<REPLAY:<name><<<` markers in that script, and a path class
(`agents/*.sh`) would exempt real edits to the workers' own governors. So this class is
CONTENT-verified: `sentinel_only_paths` (`touches-check.sh`) classifies from the PR diff —
a file qualifies iff its entire +/- delta is marker comments — and `touches_check` skips
qualifying files (reviewer-side only; callers without diff access stay strict). Evidence:
PR#941's 4-comment-line escape blocked a round the ratchet itself had compelled, resolved
only by per-issue `Touches:` amendment ceremony. **Considered:** declaration-side rule
("a governance-path pin must declare the file at authoring") — rejected as the same ceremony
addendum 1 dissolved, invisible until a round is already blocked. Residual (accepted, same
disposition as addenda 1–2): a marker-shaped line inside a heredoc/string is content — the
rubric's ordinary diff read is the guard.

### ADR-098 — Recipe validity is a platform gate, not a stack CI check

**Accepted 2026-08-04.** **Decision:** `.agents/*.yaml` recipes are parse-checked **platform-side**
by `agents/recipe-lint.sh`, called at the three points the platform already owns: `agent-session.sh`
before pod create (FATAL on a broken recipe; a break introduced by the env-card splice degrades to
dispatching un-carded rather than wedging the loop), `stack-lint` REPO-06 (sweep every stack's
recipes), and `new-stack.sh` at donor-copy time. No stack repo gains a check. The linter is
deliberately dependency-free — it uses `yq`/PyYAML when present, else a block-scalar-aware scanner
for the fatal shapes (missing colon-space, tab indentation) — because the launcher also runs inside
the agent-coordinator image, which has python3 but neither parser (probed 2026-08-04).
**Considered:** a required CI check in each stack repo (rejected: a platform contract billed to
every product repo's pipeline, and it fires after the money is spent, not before); a `check-yaml`
pre-commit hook in the donor `.pre-commit-config.yaml` (rejected as the gate, still welcome as
decor: hooks are per-clone opt-in and absent exactly where these files are written — a scripted
donor copy and agent pods committing from containers); teaching goose to fail earlier (not ours).
**Consequences:** a third recurrence of the class costs one loud launcher line and zero dollars
instead of a dead ride per arm. The residual risk is scanner false-positives where no real parser
exists; it flags only `key:<nonspace>` outside block scalars, and all 12 live recipes pass both
paths. Triggered by the sleep-tracking→circles inheritance (sleep-tracking#114, FU-126 fan-out).

### ADR-099 — The responder's daily LLM budget is binding and fails closed

**Accepted 2026-08-06.** **Decision:** the responder lane gets a hard ceiling on **spawned triage
sessions per UTC day** (`agents/responder-budget.sh`, `RESPONDER_DAILY_MAX=12`), checked before any
per-alert work and again before each spawn, with **no exemption for any alert**. It replaces
FU-113(c)'s cap, which gated on `N_TODAY >= 12 AND INC_SEEN == 0` and so blocked only a *new*
incident once twelve were spent — repeats of an already-seen incident were unbounded **by
construction**. The count is DERIVED from date-keyed ledger entries (a spawned triage writes
`fp-<fp> = "<date>|<incident>"`), so there is no counter to reset at midnight and no state to race.
The latch **fails CLOSED**: an unreadable ledger blocks triage. **Considered:** failing open, as
`subscription-latch.sh` does (rejected — that latch guards a limit the proxy enforces anyway, so
failing open costs one doomed spawn; nothing else enforces THIS budget, so failing open restores
the unbounded burn it exists to stop); keeping the per-incident cap and merely raising it (rejected
— the escape hatch, not the number, was the defect); rate-limiting at the Sensor (rejected — it
bounds arrival, not spend, and a slow storm still drains the day).
**Consequences:** alerts can now go **deliberately untriaged**, which is a state the platform must
be able to see — hence the pushed gauges and the `ResponderTriageBudgetExhausted` alert (labelled
`triage: none`, or it would spend a session reporting that sessions are not being spent). ⚠ That
alert is **`severity: warning`, not `info`**: `info` is silently suppressed cluster-wide by
kube-prometheus-stack's stock `InfoInhibitor` inhibit_rule, so the first cut fired in Prometheus
and was dispatched to nothing. An unroutable alert is worse than no alert — it looks like cover.
Blocked alerts still fire and still route to Home Assistant; only automated investigation stops,
and each blocked alert is recorded with a `budget-<date>` marker so a deliberate stop stays
distinguishable from a dropped event in `meta-alert-crosscheck.sh`. The ceiling's VALUE is now
measured in sessions rather than incidents and is unvalidated at that meaning — FU-149 soaks it.
Triggered by homelab#111 taking three sessions in 33 minutes during the GitHub Actions outage.

### ADR-100 — Merge is the gate: path-tiered CODEOWNERS, un-gating only by owner→rule replacement

**Accepted 2026-08-04, corrected 2026-08-07 (recorded 2026-08-07 — backfill; the dated decision
trail lived only in FU-068/FU-142, both archived and due to expire).** **Decision:** homelab runs
`require_approval + require_code_owner_review` with a **path-tiered CODEOWNERS** (tier 3 governance
/ tier 2 out-of-band-applied / tier 1 merge-is-deploy, temporarily owned pending the IAC-G04
sentinel). A gated path is un-gated **only by replacing the owner with a rule that is stricter than
the review it stands in for** (`pin-only-lint` in required `ci`; real edits take the operator path,
direct to master, where the check does not run). **Correction (2026-08-07):** the deny line is
*"does it take effect before a human approves?"*, **not** *"is it governance"* — the loop runs from
`master`, so authoring `agents/**`/`policy/**`/`tofu/github/**` on a branch is a **proposal**; only
`.github/**`, `.agents/**`, `devbox.json|lock` + CI-invoked `scripts/**` take effect pre-merge, and
they alone stay agent-untouchable. Fixers therefore author freely at 2am and the codeowner reads a
DIFF in the morning (prose was the wrong deliverable — #99). **Considered:** dropping owners
outright (rejected — no gate at all on merge-is-deploy paths); human-gating everything (rejected —
one-line pins sat blocked on the operator, #104/#105/#113); denying at *dispatch* instead of merge
(rejected by the correction — authoring is not effect, and a queued diff is the deliverable).
**Consequences:** mechanical lanes auto-merge behind regexes a human cannot be talked past;
CODEOWNERS carve-outs each carry their lint; tier-1 ownership is a scaffold that MUST fall when
IAC-G04 enforces on homelab; queue-time denial anywhere (e.g. the fix-debounce lane) may use only
the ❌ table. Doctrine + tier table: `docs/agents/iac-lane.md` §"The platform lane"; enforcement:
`CODEOWNERS`, `scripts/pin-only-lint.sh`, `tofu/github/repo_rulesets.tf`.

### ADR-101 — Public ingress as a platform XRD: zone classes, per-claim tunnels, credential-armed

**Status:** Accepted (operator direction 2026-08-08). **Decision:** public HTTP exposure is a
Crossplane claim (`PublicRoute`), not per-stack Cloudflare access: the composition (provider-
terraform, ADR-076) owns zone/account constants, sane defaults, the Cloudflare deprecation
lifecycle, credentials, and edge observability (cloudflare-exporter); a claim owns hostname +
backend contract only, valid solely inside its namespace's delegated subtree. Zones come in two
classes — product zones (one stack owns the whole zone) and platform zones (platform owns;
stacks are subtree tenants; cross-tenancy = a `delegations:` consent line in the OWNER's IaC).
Each claim gets its OWN tunnel + cloudflared (no shared-singleton config contention). The
capability arms only when the operator stores the scoped write token (CLOUDFLARE_INGRESS_WRITE)
— rendering works unarmed, Cloudflare stays untouched. **Considered:** per-stack CF tokens
(rejected: zone tokens are CF's finest grain — no subtree enforcement, shared blast radius);
Business-plan partial DNS (deferred: SLA-triggered, priced in the private plan); hand-managed
tofu per hostname (the ha one-off — becomes consumer #2 and retires). **Why:** the XRD is the
privilege boundary (Garage-bucket precedent), giving Enterprise-grade delegation semantics on
the Free plan. **Consequences:** zone-phase rulesets (cache, api-no-challenge Skip) cannot be
per-claim (one entrypoint ruleset per phase per zone) — the aggregation design is the named
open leg, decided no earlier than the second consumer; mechanism doc: docs/cloudflare.md.

### ADR-102 — Goals are the unit of autonomy: funded, production-terminated, self-reverting

**Status:** Accepted (operator design session 2026-08-09; validated retroactively against circles
#17→#29 and oracle-fleet goal-174). **Decision:** every dispatchable agent issue belongs to a
goal, and every goal carries one machine-parsed budget — no budget-unbound issues, ever. The
assembly merge is a MIDPOINT: the goal enters post-launch, keeps shipping to production at its
own pace (sprouts park in the goal's post-launch sub-issue, fixed in waves or singly, drawing
the same budget), and terminates only on a verdict: VALIDATED (production KPIs / operator
verdict-in-lieu green), REVERTED (idea refuted — the goal rolls back its own changes and closes
successfully-refuted; descendants die with it), or ABANDONED (budget out). Verdict authority is
per-stack: machine-KPI on the absorbable tier (oracle first), human elsewhere (IdP always).
Cross-goal movement mid-flight is PULL-only (`goal/donatable` transfers nothing until the
recipient pulls with a charter citation; one hop, then human); batch re-homing is legal only at
the close sweep. Harvest self-queue is legal only inside an open funded goal and dies with it.
**Considered:** always-inert sprouts behind FU-090 (rejected: puts the operator back per-issue);
close-time disposition ceremony at merge (rejected: merge is not the end — #17 was machine-ruled
"met" 100 min before the operator refuted it); per-issue budgets (rejected: bounds nothing
aggregate). **Why:** the #17→#29 supersession already executed this lifecycle by hand; goal-174's
19-sprout tree grew 3 generations post-close because nothing owned it. **Consequences:** the
squash boundary is the revert unit; goal-review clause renamed assembly-complete; IL-G04 and the
goal-half of FU-090 superseded; design detail: docs/agents/issue-authoring.md §Goal container.

### ADR-107 — Chainless everywhere: one harness, N subscription rails, every role routed

**Status:** Charter accepted (operator, 2026-08-13 — the subscription-autopsy session; build not
started). **Decision (3) Superseded-by ADR-112** (2026-08-23 — the one-harness monoculture is
reversed; decisions 1–2, 4–5 stand). **Decision:** (1) static model chains are DELETED, `routerMode: authoritative` becomes
the only mode; (2) every role (coordinator/reviewer/responder/retro/prober) wires to `/route` —
doctrine moves to git-owned class policy, never hardcoded models; (3) ONE harness (the claude
CLI) serves every rail — rail/model materialize as proxy-side base-URL/credential/model
translation, dispatch never pre-computes a harness, goose/opencode demote to experiment cells;
(4) **OpenCode Go joins as the second subscription rail** and §M11's ladder generalizes to
most-available-subscription-first over per-rail binding-window headroom, with a **capacity
doorbell** ringing `/coordinate` on window reset; (5) the AgentStack claim stops naming models
and names constraints (`rails`, `classPolicy`, per-rail budgets) — `claudeTier`/`guardrail`/
per-role model knobs deprecated. **Considered:** a three-segment model string
(`claude/anthropic/haiku`) — rejected for FU-127's structured form; keeping M12's degrade as a
special case — folds into the ladder; per-subagent billing in-process — impossible, hence the
shim/proxy split point. **Why:** 7d window at 87% with the router unable to steer 95% of the
pool; PR#407 (23 days of haiku rides silently on opus) priced fused semantics. **Consequences:**
preconditions + knob ledger + build order in
[`agents/chainless-redesign.md`](agents/chainless-redesign.md); the jail shim
(`scripts/claude-model-shim.py`) is the rail-split prototype the proxy inherits.

### ADR-109 — `agent-fix` means SUITABILITY; operator intent is never machinery state

**Status:** Accepted (2026-08-17, operator ruling in the design-agents sitting that followed PR#475).
**Decision:** `agent-fix` = *suitability*, its original meaning — "machine-doable; the loop MAY
be given this" — one bit, no timing, no ownership claim. `agent/queued` is the only release
valve (dispatch already requires both, so no dispatch machinery changes). `agent-fix` without an
`agent/*` state is ordinary **backlog**, not an anomaly: report surfaces render it as an
aggregate (count + oldest age), never a per-issue nag (the #405/PR#475 ⏸ clause re-words to
this). Every surface that AUTO-applies the label must have a named queue-decider (responder →
fix-debounce; goal checkpoint → budget-gated mint); the human surface deliberately has none.
**Considered and rejected:** a parking label / claim-level park for operator intent ("no new
oracle Goals until platform dogfoods v1.2") — intent gates only *operator* actions (Goal launch
is structurally human-only already), so encoding it as machinery state (`coordinator.enabled:
false`, a `parked` label) would falsify live state; it lives as a meta-state row **with an
explicit un-park trigger** (the A″ park rule). Also rejected: overloading `agent/blocked` —
that label stays strictly "technically blocked, a human must SOLVE something".
**Why:** four readers had four meanings (opt-in table / "adoption ends triage" / responder
diagnosis / ¬agent-fix as jail-lane marker) and no owning doc; oracle-fleet's backlog used the
original semantics while PR#475's clause reported it as a gap.
**Consequences:** semantics table + author/auto-apply/queue-decider inventory land in
`docs/agents/issue-authoring.md` §Label semantics (the owning doc); the chainless charter's
corpus-batch filter stops keying jail-lane on ¬agent-fix; `devbox run board` (the who-acts
operator view, platform pilot) renders backlog as aggregates and lists only human-actionable
classes.

### ADR-110 — The maintenance session: the codeowner gate is the corpus-loaded SESSION, not the per-PR tap

**Decision** (operator, 2026-08-18, the board-clearing session that proved the shape): for the
MAINTENANCE stream — no single Goal, reacting to alerts/board items — the human codeowner gate
is executed by the **operator-started, corpus-loaded jail session**: the seat reads every
master-bound edit with the design-agents corpus as context, merges when nothing
operator-significant surfaces, and escalates only the big. The Goal lane keeps its own
checkpoint model (corpus at decompose/assembly); this is its sibling for goalless streams.
**The invariant that does NOT move:** the platform (cluster identities) can never approve or
merge — CODEOWNERS/rulesets unchanged; the seat's authority derives from the human STARTING the
session (jail == human, the 2026-08-05 ruling extended from labels to merges for this stream).
**Escalation rubric:** operator contributes on the BIG — design forks, new machinery,
governance/gate changes, budget semantics, new credentials/egress, anything irreversible or
ADR-shaped. The seat lands the SMALL — alert-born fixes, thresholds/annotations, doc currency,
scaffold-tier manifests, fixture/lint upkeep — where "a bit wonky for a couple of days" is
explicitly acceptable: the alert belts are the net and rework-later is the plan.
**Considered:** per-PR human taps (measured 2026-08-18: ~12 taps in one day with "nothing
meaningful to add" — the seat had already done every read); seat auto-approve as a standing
grant divorced from session context — rejected, the corpus load at session start is what makes
the read a codeowner read. **Supersedes the per-PR reading** of the 2026-08-08 "gate stays
human" ruling; the gate stays human — the human's unit changed from tap to session.
**Consequences:** worker+bot review stays the decorrelated first gate; the seat is
verdict-writer AND merge-executor in-session; CLAUDE.md §How changes land gains the
maintenance-session paragraph in the G01-flip session (unparked same day); double-review
(subagent → seat → bot) unchanged for seat-authored work.

### ADR-111 — The merge-path updater moves in-cluster; "GitHub-hosted by design" is superseded

**Status:** Accepted (operator, 2026-08-21 — the #698 hosted-minutes design session; build =
stint S7, homelab#741). **Decision:** the `update-pr-branch` machinery (MP-T02/MP-T06) leaves
GitHub-hosted Actions: a platform-owned script run by a `*/15` Argo CronWorkflow backstop in
`agent-coordinator` + an exporter edge (`maybe_dispatch_behind` riding the ONE poller's walk),
credentialed by an `updater-git` ESO ExternalSecret minted from the `homelab-merge` App. The
per-repo callers + the reusable workflow are deleted; `MERGE_GH_APP_*` leaves the org Actions
secrets — the CI-plane exposure the dedicated App existed to contain closes with it.
**Why:** measured (2026-08-21 census): 91–96% of updater runs were the GitHub cron backstop —
~4,800 min/mo across 4 private repos at the 1-min billing floor, over the whole 3,000 quota with
zero PR traffic (#72, #698, two cycles); GitHub delivered `*/15` as ~25–35 min effective; and the
hosted-independence property was per-LEG only — CI (ARC) and review are cluster-resident, so a
cluster outage stalls the merge path regardless, and updater-current-but-unmergeable buys nothing.
**Considered:** caller migration onto the reusable (no cost change — triggers are caller-owned);
a free central sweeper in public homelab (rejected: a hand-maintained repo matrix in operator-only
`.github/` — a new two-readers surface, stack logic in the wrong home); ARC caller migration
(rejected 2026-08-20, stands — this is the reflex plane, not the ARC pool). **Consequences:** the
adRise action retires and MP-T02 becomes an executed-replay clause; the exporter gains a seventh
dispatcher (cron backstop + `GithubExporterDown/Stale` are the belts); the cron carries the
CRON-SERVICED detector from day one; FU-183's pro-rated burn alert becomes a true anomaly
detector. Supersedes the hosted-by-design line in `workflow.md` §Triggers + `merge-path.md`.

### ADR-112 — Harness support is a matrix: claude AND opencode full-support; harness is a cell axis

**Status:** Accepted (operator ruling, 2026-08-23 — the G-A fan-out pilot sitting). Supersedes
ADR-107 decision (3). **Decision:** the "one harness" wording fused two senses and is replaced.
*Sense A — full-support harness*: runs in every role/reflex and serves every rail (both
subscriptions, OpenRouter, free tiers). *Sense B — the dispatch-time pick* for a given ride.
**claude AND opencode both reach sense-A full support** (claude first — the beefiest
subscription lives there and it still lacks the in-cluster OpenRouter leg; opencode is PROMOTED
from experiment-cell to first-party: recipe support, headless permissions, full-id `-m`). The
monoculture reading is retired — **harness is a CELL AXIS, not a constant**: the scout canaries
every candidate across ALL THREE harnesses and a model's verdict is the cell VECTOR, never one
harness's failure; failed cells retry on a backoff ladder (~1h/2h) before a verdict sticks —
free-tier transients are not verdicts. **Considered:** filing this as an ADR-107 addendum —
rejected by this file's own rule 2 (a decision reversal is a new ADR, never an addendum).
**Why:** `stealth/ox-alpha` (2026-08-23) — goose 400-storm, bare-id opencode mis-resolved to a
default model, prefixed opencode drove tools fine: three harness paths, three outcomes, one
model; the 2026-08-10..17 all-`failed` canary rows are the same single-cell blindness.
**Consequences:** FU-095(b)'s cells become the standing evidence surface rather than a demoted
experiment; build = G-A children (the proxy anthropic→OpenRouter translation leg; opencode
first-party plumbing) + homelab#778 (scout 3-harness cells + retry ladder); design home
[`agents/chainless-redesign.md`](agents/chainless-redesign.md) decision 3.

### ADR-113 — Bash is glue, logic is Python: shellcheck gates the glue; no wholesale rewrite

**Status:** Accepted (operator ruling, 2026-08-24 — the shell audit after PR#862's refuted
diagnosis). **Decision:** the two-language pattern already in the tree becomes the rule —
orchestration/exec glue (dispatch, reflexes, launchers) stays bash; a component holding
decision logic (parsers, rankers, budget/policy math) is authored in Python from birth; logic
that grew inside glue extracts to Python at touch time, fix-density paced, never big-bang
(ADR-103's migration rule). ShellCheck (`-S warning`) becomes a required `ci` step over the
glue (FU-185). **Considered:** wholesale Go/Python rewrite of the orchestrators — rejected:
the 233 replay fixtures compose bash blocks by sentinel (the ratchet is bash-native and is the
platform's strongest safety investment), the glue's whole job is exec-ing `gh`/`kubectl`/
`claude` so a subprocess rewrite keeps the exec-boundary hazards while paying full rewrite
risk, and the measured defect record is ~80% domain-class (language-agnostic). Status quo —
rejected: the shell-language class (~13 recorded ids) is disproportionately the SILENT kind
(exit-0 deaths, fail-open, masked exits), and SC2318 names the exact `local`-expansion bug
that killed every model-scout tick for six days (#854/#862). **Why:** measured, not tasted —
at ~2,800-line scripts a human can no longer hold bash while LLMs can, and the lint is what
holds them. **Consequences:** FU-185 wires the gate + burns the ~8 standing warnings; the
inline shell in `responder-argo.yaml`/`fix-debounce-argo.yaml` is the first extraction
candidate at its next touch; "which language" is a review-rubric question for new components.

### ADR-108 — Observability stays out of routing-critical paths; meters push, critical paths never pull Prometheus

**Status:** Accepted (2026-08-13, operator ruling on homelab#438).
**Decision:** two halves. (1) The jail's Go-rail usage meters ITSELF (shared `gometer` module,
one home beside the proxy) and PUSHES rows to a token-gated ingest listener on a separate
proxy port/VIP — the jail never routes traffic through, or depends on, the cluster: **the jail
must be able to fix the cluster, so nothing in its toolchain may require it.** (2) The general
principle behind rejecting the Pushgateway alternative: **Prometheus is observability, not a
routing input — no dispatch/latch/routing-critical path may pull from it.** If metrics ever
must become routing-critical, that is a SEPARATE Prometheus carrying business-critical series
only, with its own tighter SLA and access model — never the observability instance.
**Considered:** routing jail Go traffic through the cluster proxy (rejected — inverts the
jail→cluster dependency); Pushgateway + PromQL windows for the latch (rejected — moves window
arithmetic into range queries and puts the observability Prometheus in the /opencode-limit
accuracy path).
**Why:** the first console reconciliation (2026-08-13) showed the cluster meter seeing 12% of
account usage; the fix must not weaken the jail's recovery-seat role. The existing
`CREDIT_METRICS_URL` leg (homelab#180) is the tolerated boundary case: a soft capacity hint
with a fail-open degrade, not window accounting — new designs don't get to cite it.
**Consequences:** chunk G (homelab#438) builds the module split + ingest; the ledger sqlite
stays the single window authority; operator console usage stays unmetered by declared practice
(operator: paid rides go through claude-go; the opencode TUI is for free-model play only).

### ADR-106 — Goal lane v1.2: single-mode feature goals, origin lineage, the findings store, a demoted fence, a freed mutex

**Status:** Accepted (operator design session 2026-08-12 — the A3 sitting; evidence =
[`spikes/goal-lane-v1.1-fu165-pilot.md`](spikes/goal-lane-v1.1-fu165-pilot.md), priced by the
objective function: codeowner-touch count first). **Decision:** (1) a Goal is FEATURE-shaped
only — children merge into `goal/**`, ONE assembly PR = the one codeowner tax; per-child-to-
master work is NOT a Goal (ordinary queued issues) and the v1.1 master-lane variant is RETIRED
— the operator: the shape was the defect, "I could have held all the features back and merged
them once and nothing bad would have happened". (2) Sprouts parent to their ORIGINATING issue
(native derivation — the budget walk and close sweep are transitive; the bucket returns to
ADR-102's original role: post-assembly strays only). (3) One typed FINDINGS STORE per goal
(machine comment; harvest APPENDS, never mints; count-keyed `dispositioned-through:` marker) +
CHECKPOINT sessions (reasoning tier) on N≥5 new entries / a child-set completing / a budget
fraction / pre-verdict; per-closure goal-review demotes to a deterministic burn-down append.
(4) `Touches:` demotes to metadata (dispatch ordering, the static ❌/pin-only intersections,
coupling docs); declared ≤~20-line folds allowed; governance enforcement becomes a MECHANICAL
lint (worker-authored diff ∩ governance paths incl. `.agents/**` = red). (5) Concurrency:
doorbell fixed-name collapse + the `coordinator-scan` mutex scoped to the deterministic phase;
ADR-094 item-scoping untouched; re-measure before more. (6) Goals are STACK-scoped — the claim's
repo list incl. `-iac`, sibling-repo doorbells, `Production-leg:` verified in-tree through the
deploy. **Considered:** dual feature/wave modes (rejected — post-launch already accommodates
ship-then-fix; adding a mode adds complexity for a shape that should not recur); N-unit dispatch
and the worker rail move (deferred/rejected — spike + model-routing §M12). **Why:** the v1.1
measurements — 2-vs-5 generations, 52/52 worker-authored inflow, 21 rulings/46 mints, the fence
7× against with zero conflicts, 3,550-vs-605-minute dispatcher famine — each read against
codeowner economics. **Consequences:** ADR-102's bucket text is fully correct again; the
IL-T15/T17 master-lane disposition simplifies away; the ADR-097 footprint HOLD and the #270
replay coupling retire (conflicts route via the updater/MP-T06 as measured); FU-090's gauge =
the exporter's existing walk over now-native depth; build items = Bucket A4/A2 then the next
Goal's children; doc homes: issue-authoring.md, model-routing.md §M10, workflow.md.

### ADR-103 — The platform develops itself like a stack: replay-gated clauses, human-only timelines, weekly self-KPIs

**Status:** Accepted (operator 2026-08-09, from the 2-day failure census + recurrence audit).
**Decision:** three standing rules. (1) A changed coordinator clause, prompt-assembly path, or
reflex ships only with an EXECUTED replay (recorded API state in → expected dispatch/label/
comment out), enforced by a ratchet lint keyed on the FSM's new `replay:` fields — new/changed
transitions red without one; backfill follows fix-density, not big-bang. (2) Issue timelines are
for humans: machine residue (state-fp markers, run-stats, dispatch/deferral notices) moves to
check-runs/commit statuses/S3/Prometheus; bar = a new PR shows the review verdict plus at most
ONE machine comment. (3) The Monday retro scores two platform KPIs weekly — bucket-A (platform-
logic) incident count and jail $/day-equivalent — and proposes the next gate; sustained non-fall
is the trigger to revisit label-carried loop state (AgentStack CR status instead).
**Considered:** more durable prose warnings (rejected by the recurrence data: every prose-warned
class recurred; every executable gate held); big-bang FSM spec-first (rejected: POC-first stands
— replay a seam when its fix stream shows the shape stopped moving). **Why:** 14 of 31 failure
events in 2 days were platform-logic; ~2/3 of timeline comments are process residue; the four
existing exemplars (state-fp replay, responder harness, rail-degrade replay, prompt-transport
lint) each ended their class. **Consequences:** clause work slows slightly and stays fixed;
the debounce's comment-store moves last (load-bearing, replay-first); mechanism docs:
docs/agents/workflow.md (replay ratchet), observability-and-retro.md (channels); the weekly KPI
spec lives in docs/agents/retros/BRIEF.md (pointer fixed 2026-08-10 — it never lived in
observability-and-retro.md).

### ADR-104 — Research routing: deterministic slot draws on curated pools; resilience from shape, not rules

**Status:** Accepted (operator design session 2026-08-10, from the circles run + scout digest #234).
**Decision:** (1) `/route` gains a deterministic draw form — `class` (selects a curated pool) +
`slot` (index into its ranking) + `jitter: false`; response carries the pool version; same inputs
→ same model (idempotent relaunch). (2) Pools are CURATED weekly by the scout (ranked,
family-deduped, disjoint bands by convention: regular/premium/ultra/instrument) — never computed
in the request path; diversity is a curation property. (3) The research process carries NO
enforcement machinery — no roster validation, exclusion invariants, or retry protocol:
over-provision (ask for 7, need 5) + visible provenance (arm tables, chips) are the resilience,
because research is operator-driven with a human at every judgment point. (4) The scout canary is
a RAIL probe (cheap rung-1 for every pool entrant); capability eligibility comes from the
benchmark feed, never from riding research-sized tasks.
**Considered:** a mission-aware router (step/roster/exclude server-side) — rejected, leaks
roles.md internals into the mechanism layer; N independent jittered `/route` calls — rejected,
non-reproducible and diversity-blind (converges on one cheap band).
**Why:** fan-out needs N diverse models, not one best; experiments need reproducibility (jitter
is exploration budget for volume dispatch, corruption inside a ~13-call mission); enforcement
belongs to autonomous lanes, visibility to operator lanes.
**Consequences:** scout v3 (FU-161) + draw verb/pools (FU-162); `research-fanout.sh` becomes the
first consumer (the circles flash/pro roster slip is the draw-over-hand-pick evidence); process
doc `docs/agents/research-and-specs.md`; mission budget deliberately unsettled until the idp run
(FU-126).

### ADR-105 — Jail skills: a gap ledger + batched transcript retro, not self-editing skills

**Status:** Accepted (2026-08-11, operator design session).
**Decision:** skill shortcomings are FU-shaped sightings in `.claude/skills/GAPS.md` — file on
sighting, extend with a date on re-sighting, ≥2 dates = a class → promotion moves the rule into
the skill with dated provenance (operator-gated) and closes the entry in the same commit.
Detection is batched: the `skill-retro` skill (the jail twin of the cluster retro,
`docs/agents/observability-and-retro.md` §B2) sweeps dialogue-only slices of FINISHED jail
transcripts (`scripts/skill-retro-scan.sh` + `render-transcript.py --dialogue`); every skill
opens with a GAPS glance-step (delivery). Contract: `.claude/skills/README.md`.
**Considered:** per-skill log files (fragments cross-skill classes — the dead-probe class spans
three skills); a trailing "improve this skill" line in every skill (N copies of one fact, fires
at peak confidence); Stop/SessionEnd hook injection (Stop = every turn, wrong timing; SessionEnd
cannot reach the model); correction-time logging alone (attribution is a second-order reflection
— unreliable).
**Why:** transcripts record everything with zero session cooperation; hindsight makes
attribution easy; the corpus view is where classes emerge; single-sighting codification is the
G05 failure mode (contracts emerge from patterns).
**Consequences:** GAPS.md is public (dialogue-level facts only); TICK-LOG keeps narrative; skill
doctrine changes stay operator-gated except plain factual wrongness.

### ADR-115 — Provider selection prices the JOB: Exacto delegated for cheap classes, an overhead-cost pin for priced ones

**Status:** Accepted (2026-08-26, the 0731 intake session — evidence in model-routing.md §M14).

**Decision.** Provider choice is priced per successful JOB, not per token:
`expected_cost = eff_price × tokens + p(fail | provider, model) × C_overhead`, where C_overhead
is the measured downstream cost of a failed ride (strike + re-dispatch + coordinator session +
review rounds). Consequences, per class (`provider_policy` in model-classes.json — git POLICY):
**cheap coding classes DELEGATE to OpenRouter's Auto Exacto** (drop our `provider.order` pin so
upstream's tool-call-quality ordering runs — at flash prices the failure term dominates any
price delta we could optimize); **priced classes (research/audit/weave) keep OUR pin, upgraded**
(§M14 pin-v2: 15% band + serving-quality tie-break, benchmark provider-floor, live
tool-call-error floor, (model, provider) pair-cooldowns — the #783 legs).

**Considered.** Exacto-only (rejected: a price doubling is real money on the priced tiers, and
experiments need deterministic provider arms); pin-v2-only (rejected: reverse-engineers at n=dozens
a signal upstream measures at n=millions and maintains for us — the outsource-staleness lens);
status quo (rejected on the day's evidence: the quality-blind pin chose an fp4 serving over the
top-quality first-party serving to save $0.0012/M while provider tool-call error rates on ONE
model span 0.2%→40% and our strikes carry no provider).

**Why.** The 0731 read: the M4 pin structurally samples the mid/bottom of the serving-quality
distribution (Relace/OpenInference/DeepInfra; DeepSeek first-party never ridden), a 39.6%
tool-error provider (DigitalOcean) sat pin-eligible at 99.6% uptime, and the elite tier
(Fireworks 0.23%) costs ~3× on prices where 3× ≈ cents/month against ride-deaths that cost
coordinator sessions.

**Consequences.** The scout canary rides its class's provider policy (representativeness = same
policy, not same provider); `@provider_slot`/`@slug` arms (built, PR#963) stay the experiment
instrument; the tool-call-error-rate feed becomes alerting + pin input, never blind trust;
0731's re-admission to model_tiers rides the §M14 matrix run. Build pointer: FU-186.

### ADR-114 — Garage rf=3 across physical zones; engines replicate, Longhorn stores singles

**Status:** Accepted (2026-08-24, operator design session over the garagehq real-world/layout
docs; deadline-bound — oracle serves production ~2026-08-31).
**Decision:** replicated data engines stop stacking on replicated storage. Garage moves to
`replication_factor = 3`, one instance per physical zone (`wk-metal-01`, `wk-metal-04`,
`proxmox`/wk-02 as the interim third — a disk added to hp-01 replaces it later via
`layout assign` + rebalance), each on **node-local XFS** (not Longhorn; ext4 inode limits bite
at loki/ert object counts), zones = `topology.kubernetes.io/zone` from `machines.yaml` (new
`zone` field: physical box = zone, every pve-pool VM = `proxmox`). LMDB stays (upstream:
recommended for rf ≥ 2; corruption recoverable from peers) with `metadata_fsync = true` + 6h
native snapshots kept. CNPG gets the same treatment: replica-1 storage + **required**
zone anti-affinity (soft anti-affinity healed forgejo-pg into two instances on one VM,
then both instances in one failure domain, 2026-08-24). Backup shrinks to the
logical-deletion class (Garage has no S3 versioning): an in-cluster CronJob syncs objects to a
std-tier Longhorn PVC, alerting via pushgateway; offsite stays parked (FU-137).
**Considered:** rf=3 on Longhorn (6 copies, zones opaque to Garage); SQLite engine (the
single-node mitigation — moot at rf=3); keep rf=1 + belts only (availability gap remains — the
2026-08-24 incident cost 70 min of platform S3 on one VM freeze).
**Why:** the real failure domain is the pve thin pool, not a node — placement must encode it;
Garage's whole recovery doc assumes rf ≥ 2; capacity fits by reclaiming Garage's own 150Gi×2
Longhorn footprint from the same metal disks.
**Consequences:** layout ops get a version-disciplined script (apply-once-per-version, single
RPC host); `docs/garage.md` §Target architecture carries the mechanism; FU-137 tracks
delivery; SERVICES.md unchanged (endpoints stay).

### ADR-116 — FU ids are stable coordinates: provenance refs never scrub (the name-anchor ruling)

**Status:** Accepted (2026-08-26, operator ruling input in the S5 stint — homelab#981; the
2026-08-25 docs-cleanup measured the problem: 29 expired archive entries whose living refs are
overwhelmingly provenance names, FU-088 ×51, FU-069 ×26, FU-057 ×20).
**Decision:** an `FU-NNN` string in living code/docs is by default a **provenance name** — a
stable coordinate in the never-reused id namespace — legal forever, surviving the archive
entry's expiry. Only **TODO-shaped** references must resolve to open work, and the mechanized
shapes are exactly two: `FU: FU-NNN` (FSM gap-register disposition cells) and `Tracked by`
lines. `follow-ups-lint` enforces it: DANGLING now fires only at/past the tracker's Next-free
counter (a typo'd id that never existed); TODO-RETIRED (fail) / TODO-ARCHIVED (warn) police the
two forward-pointing shapes.
**Considered:** scrub-all-on-expiry (the prior convention — measured as mass destruction of
design provenance for zero drift protection); colon-form comments as a third TODO shape
(measured ambiguous: `# FU-085: this run may have opened…` is provenance, not a TODO); heading
renames per doc (rot addressed separately — the §-code convention, S5 #982).
**Why:** one-ID-namespace + deletability (../teststuff specs-for-agentic-delivery.md): a name
that cannot be reused cannot dangle semantically; only forward pointers can lie.
**Consequences:** archive expiry becomes a cheap mechanical sweep (29 deleted in the ADR's own
PR); `git log -S FU-NNN` stays the deep record; the residual risk — a genuine TODO written as a
bare colon comment outliving its id — is accepted and left to cleanup-pass judgment.

### ADR-117 — Referenced doc sections carry stable §-code heading anchors (the M-code convention generalized)

**Status:** Accepted (2026-08-26, operator ruling input in the S5 stint — homelab#982; the
sibling of ADR-116, which rules the FU-id half of the same rot problem).
**Decision:** a doc section that other docs or code reference gets a stable CODE as its heading
prefix (`### M14. …`; list-structured sections use a bolded lead, `- **L0b — …`), never reused
and never renamed; the reference writes `§<CODE>`. `docs-graph-lint` check #4 enforces it
two-way — ANCHOR-UNRESOLVED (a §-ref with no living definition) and ANCHOR-AMBIGUOUS (a code
defined twice) — in SHADOW (warn-only) until a clean-run record flips it, the check-#3 arc.
The `§` sigil is the opt-in: only §-referenced codes are checked, and only the doc-heat-hot
set grows codes — cold docs are never coerced.
**Considered:** prose section-name refs (the status quo — they rot silently on heading edits
and no lint can see them); markdown slug anchors (`#the-section-name` — rot identically, and
GitHub's slugs are derived, not stable); blanket-coding every heading (ceremony on cold docs
nobody references — rejected per the doc-heat rule).
**Why:** ids grep, headings rot — M-codes/FSM-ids/FU-ids never dangled while prose §-refs did;
the same one-namespace property ADR-116 leans on (a never-reused name cannot dangle
semantically, only forward pointers can lie).
**Consequences:** referenced sections accrete codes at touch time (no big-bang renaming);
report-local codes (retro F-codes, fixer-context L-layers) stay legal un-sigiled; a future
§-ref to a reused code surfaces as ANCHOR-AMBIGUOUS and forces the rename the convention
demands.

### ADR-118 — Loki multi-tenancy is the data model; an RBAC-authorizing proxy is the enforcement
**Status:** Accepted (2026-08-27). **Decision:** give per-tenant log reads a **two-part** mechanism —
`auth_enabled: true` on Loki with **tenant == namespace** (Alloy stamps the tenant from the pod's `namespace` label — no mapping table; ⚠ correction
#1009: the relabel-rule form written here silently no-ops (`__`-prefixed labels drop before
`loki.write`) — shipped as `stage.tenant`, see loki-tenancy.md §Why tenant == namespace), plus **kube-rbac-proxy**
in front doing TokenReview → SubjectAccessReview with the SAR's namespace rewritten from
`X-Scope-OrgID`. Scoping is then ordinary RBAC: a RoleBinding for `loki-tenant-reader` in ns `<n>`
IS "may read tenant `<n>`". First and only consumer: the **oracle stack jail's workbench SA**.
Design, rollout order and the tightening path: [`loki-tenancy.md`](loki-tenancy.md).
**Considered:** tenancy ALONE (rejected — `auth_enabled` does not authenticate, it *requires and
trusts* the header, so direct reach still reads any tenant); a query-rewriting endpoint on the
egress proxy WITHOUT tenancy (rejected — a security-critical LogQL parser kept correct forever over
co-mingled chunks, where one bug is full disclosure; it is bespoke there only because that proxy
also injects credentials, which a read gate never does); tenant == STACK (rejected — needs a
namespace→stack map inside Alloy, a second reader of the claims beside `stacks_json()`, and the SAR
rewrite splits per header OCCURRENCE not per delimiter, so Loki's `a|b|c` syntax cannot be
authorized in one call anyway); Traefik ForwardAuth / Gateway API `ext_authz` / oauth2-proxy / a
mesh (rejected — a second ingress controller, not first-class in Cilium, needs the PLANNED IdP, and
standing "no Istio" respectively); exposing Loki itself on a VIP (rejected — unauthenticated, and
WireGuard clients see VIPs, so that publishes all cluster logs to every device on the network).
**Why:** the binary today is nothing-or-everything, and the platform already asserts a "LogQL
access" capability (homelab#541's kmsg carve-out) that nothing provides. Tenancy also brings
per-tenant ingest limits — the homelab#811 containment that did not exist — and per-tenant
retention. kube-rbac-proxy is adopted with its alpha/non-sigs status recorded rather than glossed:
the trade bought is declarative RBAC over code, and its failure mode is "jail log reads stop".
**Consequences:** rollout is three ordered steps and step 1 must NOT be exposed (a proxy in front of
a single-tenant Loki authorizes one tenant and serves all — the one state worse than nothing);
in-cluster reach stays unscoped by design, so the door is bypassable from inside until Loki binds
to localhost and Alloy's writes get their own gate; a second consumer stack turns the hand-written
grants into an AgentStack claim knob (mechanism = platform, policy = stack).

### ADR-119 — Stack→platform communication: the claim is the API; demand travels as intents, escalation files direct (2026-08-30)

**Decision (three parts).** (1) *Doctrine*: a Goal is stack-scoped; code write never crosses
stacks; cross-stack need travels as claim-contract fields requested through the
capability-request lane, plus native `blockedBy` edges for sequencing. (2) *The lane*: a stack
files an issue in its OWN repo labeled `platform-request` with an intent-level `Capability:`
fingerprint (an outcome on a surface — `public-edge.abuse-fairness` — never a vendor/mechanism
name: mechanism knowledge is the platform's, ADR-085 drawn through the request grammar); the
homelab board groups by fingerprint (the ≥2-stacks generalization gate becomes a count);
approval is PULL-only with a disposition comment always (rejection included). A capability whose
honest consumer answer is always "yes" (security, performance) is a DEFAULT of its profile,
never requestable. (3) *Escalation*: a stack-lane judgment terminal that diagnoses a
cross-boundary cause FILES direct on homelab — dedup-first, inert, evidence-grammar (the filing
contract in the coordinator brief) — plus a cross-repo `blockedBy` edge from the stuck stack
issue, so un-park rides the existing FU-087 dependency gate. The stack names the boundary
crossing; the platform's own intake names the lane (mechanical vs agents-machinery).
**Considered:** mechanism-named fingerprints (systematically miss normal-consumer demand — the
WAF case); destination labels on stack repos (passive state on repos the platform deliberately
does not sweep — needs a new cross-stack reader); stack-side platform-component classification
(the same knowledge asymmetry as the fingerprints). **Why:** three scars in one week —
proposals hand-routed as gitignored uploads; sleep#133's arbitrate ruled "infra, not logic"
with nowhere to route; #1038 reached the platform only via the fleet rule's ≥2 gate and its
un-park was manual. **Consequences:** mechanism = platform-and-stacks.md §Cross-stack demand &
escalation; filing contract = agents/coordinator/README.md; label via the claim taxonomy.
Damage ceiling: filed-inert (breaker #1) + dedup + rate cap; gate-the-merge unchanged. Honest
limit: the lane cannot carry unknown-unknowns — profile defaults for the yes/yes class and the
FU-049 catalog carry those.

### ADR-120 — The global coordinate surface is the switchboard: a Sensor-edge resolver, its cron retired (2026-08-31)

**Decision.** With all four stacks graduated, the global coordinate machinery is rebranded to
what it actually does: the **switchboard** — the `/coordinate` Sensor's global trigger + a
`switchboard` WorkflowTemplate whose run resolves repo-dumb rings to their stack's doorbell
(FU-144) and fans capacity transitions out fleet-wide (issue#779), then exits before any GitHub
listing (`coordinator-scan.sh --switchboard`). It holds no mutex and no subscription semaphore.
The `coordinator-reflex` global cron and `devbox run coordinate-now` are RETIRED; the per-stack
`coordinate-<stack>` crons are the level-triggered failure detector. An ungraduated stack
therefore has NO scan path until its claim flips `loop.perStack`/`graduated` — the switchboard
warns loudly per ring. The shared `/coordinate` webhook path is deliberately unchanged (payloads
route; renaming the wire would break every emitter for no stack-facing clarity).
**Considered:** keep-as-is (92% of global runs were full board sweeps that dispatched nothing —
homelab#994, worsened by #974's 1Gi cap); scan-side early exit alone (kills the waste but keeps
the "coordinator" name that misroutes stack sessions — the FU-163 stale-by-addition collision);
Sensor-side loop_ns filter (Argo data-filter validation risk = the FU-085 lost-edge class;
optional follow-on). **Why:** measured — 110/119 junk runs (2026-08-26), 18/18 no-op cron ticks
over 3h (2026-08-31), cron fan-out structurally forbidden, per-stack crons already carry the
backstop duty. **Consequences:** coordinate-argo.yaml + the scan's switchboard terminal
(replay: `doorbell/switchboard-*` ×4); reflexes-argo.yaml + devbox.json operator-direct
(eae8c51f); closes homelab#994; glossary row `switchboard`.

### ADR-121 — First-party artifacts: a push-mode registry on Garage, ghcr demoted to CI images (2026-09-02)

**Decision.** A first-party **push-mode** OCI registry — `registry:3` on the **Garage S3 driver**
(bucket `registry`, 20Gi cap, platform-owned Workspace — the loki shape), ns `registry`,
`argocd/resources/registry/`. **Anonymous LAN pull, authenticated push** (operator ruling
2026-09-02): an nginx front applies basic auth to every method except GET/HEAD — distribution
cannot express per-method auth. Exposure is the standard pair (`registry.teststuff.net`,
HAProxy `3.33` ↔ LB `40.33`, LE cert) so containerd trusts it with **zero node config** — no
insecure-registry anywhere (operator constraint). First consumer: the oracle `ert-corpus`
(6.4GB/release, built in-cluster, staged on Garage) — release dual-pushes ghcr + here, the
oracle-iac pin flips to this name; ghcr keeps CI/base images (ADR-082 unchanged).
**Considered:** stay on ghcr + mirror creds (FU-196 v0 — LIVE, but every cold pull is a WAN
roll: 429 storms oracle-fleet#274, mid-stream PROTOCOL_ERROR kills + a poisoned mirror commit
#1282, a NodeSystemSaturation page per pull — 6GB out + 6GB×N back over WAN for bytes built
50cm from their consumers); Harbor/zot (re-rejected per ADR-091 — this IS the reserved
"first-party hosting moves in-house" revisit, and one distribution instance still covers it);
Longhorn PVC backend (bulk tier 88% committed; corpus is data → S3, CONTEXT.md #1);
Forgejo's package registry (couples a trial-status forge to the serving path).
**Consequences:** corpus pulls never leave the LAN; the #1282 concurrent-cold-pull poison
window closes for this class (push at release = born warm); retention is REQUIRED before the
weekly delta cadence un-suspends — **FU-203** (tag-aware prune; the policy a pull-through
could never express). Push cred: Infisical `REGISTRY_PUSH_{HTPASSWD,TOKEN}`; the Actions repo
secret is an operator console step (secrets.md §Minting doctrine item 2). FU-196 tracks the
consumer cutover.

### ADR-122 — Issue authoring is dumb, the container disposes: filing is inert, a tree member has a disposition, the walk retires (2026-09-03)

**Status:** Accepted (operator direction 2026-09-03, the design-agents sitting after the G-G
assembly; build = the re-headed S8, ROADMAP work map). **Decision:** (1) **Filing is inert, no
exceptions.** No reader queues an issue from its shape; the bare-tree-member walk (#1153 →
PR#1242) retires. Queueing under a Goal happens only at the two authoring moments ADR-106 names
(decompose, checkpoint mint) or by a human applying `agent/queued`. (2) **One release valve.**
`agent/queued` means go; `agent-fix` leaves the author's surface as a dispatch precondition
(it stays ADR-109's backlog marker). Class (`fix`/`build`/`goal`) stays author-declared, as a
field, not a label. (3) **One machine block, one parser.** The line-anchored body grammars (13
today; `Touches:` is parsed in 9 files) collapse into a single front-matter block read by one
shared Python function every consumer calls (ADR-113); `Origin:` joins it. (4) **Lineage is
dumb, disposition is the container's.** A filing binds to its origin issue at ANY door without
judging scope (rule 8's mint-to-origin stands; `Origin:` makes a later move free). A tree
member carries a disposition — `undispositioned` | `adopted` | `deferred` — written only by the
container's checkpoint/closeout act. An undispositioned member WAKES the checkpoint (a finding
in the tree, trigger (a)'s shape) and never blocks it; the completion predicate counts
adopted-open members only; `deferred` keeps lineage, leaves scope, and the container may move
it — the `post-launch:` title exception (#933) dissolves into this state. **Considered:** one
more authoring rule + a goal-lint clause (the pattern of the last five fixes — rules 7–9,
goal-lint, the walk, the Touches lint — each ADDED a reader; #1338 was authored correctly and
still went wrong, so no linter helps); a `goal/deferred` label applied by the filer (rejected:
the filer is the wrong actor); provenance-only filing with no tree binding (rejected same
sitting: the container knows its rules better than the filer). **Why:** measured 2026-09-03 —
13 body grammars, 23 machine-meaningful labels, 6 comment markers, 2 edge kinds, a 159-line
consumer card, and ≥4 readers that MUTATE author state. A Fable-class seat authored #1338
correctly; the walk re-queued it 86s later, cost a ride and a false SOLVE row; #1334 the same
morning, twice (#1249); #1315's undispositioned binding held G-G's assembly ~10.5h because
trigger (b) counts every open member; #390 half-minted on #175 with no reader. The sum of
individually-right readers is unauthorable — the A5/doorbell shape. **Consequences:** the walk
deletion is hotfix-class (one scan block + a replay row) and may land before the stint;
(2)–(4) are S8's new head (issue-authoring.md §lineage contract rule 9, version row v1.4);
ADR-109's "dispatch requires both" and ADR-106 (3)'s bucket-by-title are superseded in part;
v1.3.1 delta 3 (`Origin:` + typed defer/release) is subsumed; IL-T17's bucket exclusion becomes
an ordinary disposition. Not changed: the fingerprint-debounce faces (FU-199) and the router
defects (#1342) — separate classes, replayed 2026-09-03 and untouched by these rules.

### ADR-123 — Operational paths are non-public by default: the edge blocks them on every PublicRoute; the health contract is the platform's to evolve (2026-09-03)

**Status:** Accepted (operator direction 2026-09-03, at the oracle-iac#532 pre-merge read; build =
FU-206). **Decision:** (1) A PublicRoute serves the claim's backend to the internet, but the
backend's **operational paths** — `/metrics`, `/healthz` and their kin — are non-public by
default: the composition blocks them at the edge for EVERY claim, both profiles, as one more rule
in the claim's `http_request_firewall_custom` ruleset (a structured 403, never a challenge); a
claim that genuinely wants one public opts in per path. Enforcement is edge-side, never an
app-side IP allow-list: the LAN scrape/probe path stays open and the app carries no knowledge of
its own exposure. (2) The health endpoint's CONTRACT is the platform's and will evolve: today
`/healthz` answers the kubelet ("am I ready"); multi-origin service (ROADMAP §HA model rung 3 —
Cloudflare LB, home primary + Civo failover) needs an answer that RANKS origins ("am I better
than the other datacenter"), which a single app cannot know — that contract is designed
platform-side when rung 3 is built, and no app's `/healthz` shape is public API until then.
**Considered:** app-side allow-lists (rejected: every app re-implements exposure knowledge, and
the LAN route is the same Deployment); a claim field only (rejected: ADR-119's always-yes class
— an honest consumer never wants `/metrics` public); waiting for the ≥2-consumers rule
(overridden: security-shaped, the default is the safe side, the opt-in is the escape). **Why:**
the first api-profile claim (oracle-iac#532) would have served the gateway's Prometheus exposition
to the internet — the gateway answers `/metrics`/`/healthz` before auth by design and the tunnel
forwards the whole hostname. **Consequences:** composition change (FU-206); on the platform zone
the same phase is the ha mTLS entry point, so teststuff.net claims get it only with zone-phase
aggregation (FU-039's leg); the health-contract leg is a rung-3 design item, named here.
