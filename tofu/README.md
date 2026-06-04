# `tofu/` — Talos k8s cluster on Proxmox (Phases 1 & 2)

Provisions a Talos Linux Kubernetes cluster as VMs on the Proxmox host (`pve`,
`192.168.2.3`), installs Cilium as the CNI, exposes services on the LAN via Cilium
BGP, and runs Home Assistant on it. Implements ROADMAP.md Phases 1–2.

> **Status: APPLIED & LIVE.** Talos `v1.13.2` / Kubernetes `v1.36.1`, Cilium `1.19.1`
> (kube-proxy-free). Nodes: VMs cp-01 `.51` / wk-01 `.61` / wk-02 `.62` **+ bare-metal**
> thinkcentre `.53`, hp-01 `.54`, wk-metal-01 `.182` (X240), wk-metal-02 `.183` (X250) — all
> `Ready`. **Longhorn** is the storage; Home Assistant, the **UniFi controller**, and the
> monitoring stack run in-cluster on BGP VIPs (`192.168.40.0/24`). State is local
> (`terraform.tfstate`, gitignored). Always `tofu plan` and review before any `apply`.
>
> Bare-metal node onboarding is its own procedure — see `../docs/provisioning.md`.

## Pinned versions

| Thing | Version |
|---|---|
| Talos Linux | `v1.13.2` (Kubernetes `v1.36.1`) |
| Cilium (CNI) | `1.19.1` |
| `bpg/proxmox` | `~> 0.107` |
| `siderolabs/talos` | `~> 0.11` |
| `hashicorp/helm` | `~> 2.17` |
| `hashicorp/kubernetes` | `~> 2.31` |

Provider hashes are pinned in `.terraform.lock.hcl` (committed, on purpose).

## Layout (why it's split this way)

**Cluster (provider-agnostic)** — reused unchanged in a DR rebuild onto other infra:

- `talos.tf` — Talos machine config, bootstrap, kubeconfig. Patches: install disk
  `/dev/sda`; `cni=none` + `proxy.disabled=true` on control-plane (Cilium owns CNI and
  service routing); a kubelet `extraMount` for `/var/mnt/homeassistant` (Talos rootfs is
  read-only, so hostPath PVs need a writable bind).
- `image.tf` — Talos Image Factory schematic (+ qemu-guest-agent) and the node download.
- `cilium.tf` — Cilium Helm release. `kubeProxyReplacement=true` via Talos KubePrism
  (`localhost:7445`), `bgpControlPlane.enabled`, Talos-specific cgroup/capabilities,
  `operator.replicas=1`. Recreating the cluster restores the CNI (boot-from-git).
- `cilium-bgp.tf` — service exposure on the LAN. `CiliumLoadBalancerIPPool 192.168.40.0/24`,
  BGP cluster ASN `64513` peering OPNsense ASN `64512` (`192.168.2.1`); only Services
  labelled `bgp=advertise` are advertised. **OPNsense side is `../ansible/opnsense-bgp.yml`**
  (os-frr) — both ends are code.
- `homeassistant.tf` — Home Assistant via the kubernetes provider: namespace, **Longhorn** PVC,
  Deployment, and a `LoadBalancer` Service pinned to VIP `192.168.40.10`
  (`lbipam.cilium.io/ips` + `bgp=advertise`).
- `unifi.tf` — UniFi Network Application + MongoDB on Longhorn (replaces the dead T61 controller);
  `LoadBalancer` VIP `192.168.40.12` (mixed TCP/UDP). **Applied & live**; image pinned by digest.
- `longhorn.tf` — Longhorn storage (default StorageClass, replicated) + a `longhorn-fast`
  node-local tier on the ThinkCentre's Optane.
- `metal.tf` — bare-metal Talos workers (PXE/USB-installed, not Proxmox VMs); see
  `../docs/provisioning.md`.
- `monitoring.tf` — Prometheus + Grafana + Alertmanager (BGP VIPs `.13`/`.11`/`.14`).
- `outputs.tf` — `talosconfig`, `kubeconfig`, `cluster_endpoint`, `home_assistant_url`, `unifi_url`,
  `grafana_url`, `monitoring_urls`.

**Hardware-specific** — swap these for the DR target; the cluster layer stays put:

- `proxmox.tf` + `providers.tf` — Proxmox VMs and the provider (incl. the SSH block bpg
  needs for disk-image import).

**Inputs** — `variables.tf` / `locals.tf` / `terraform.tfvars.example`. `nodes` is a map
(deterministic `for_each`); keep it sorted by key, IPs must be free / OPNsense-reserved.

## Prerequisite — create a Proxmox API token (Phase 0)

bpg drives the Proxmox API with a token. On the `pve` host:

```bash
# Dedicated, scoped user + token (preferred)
pveum role add TerraformProv -privs "Datastore.Allocate Datastore.AllocateSpace \
  Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console \
  Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit \
  VM.Config.CPU VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network \
  VM.Config.Options VM.Migrate VM.Monitor VM.PowerMgmt SDN.Use"
pveum user add tofu@pve
pveum aclmod / -user tofu@pve -role TerraformProv
pveum user token add tofu@pve provisioner --privsep 0   # prints the secret ONCE
```

Then export it (don't put it in a committed file):

```bash
export TF_VAR_proxmox_api_token='tofu@pve!provisioner=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
```

> The live cluster was bootstrapped with a broad `root@pam!tofu` token (in the gitignored
> `terraform.tfvars`) — **burnable: rotate to a scoped `tofu@pve` token + SOPS before this
> repo goes public** (see `../PUBLISH-CHECKLIST.md`). The SSH key bpg uses for disk import
> lives outside the repo at `~/.claude/homelab-pve-ssh/` (authorize its `.pub` in pve root's
> `authorized_keys` — the one-time root-of-trust seed; no Proxmox API can inject it).

## Use

```bash
devbox shell                                   # toolchain (tofu/talosctl/kubectl/helm) from ../devbox.json
cp terraform.tfvars.example terraform.tfvars   # edit IPs/specs (must be free IPs)
tofu init
tofu validate
tofu plan
tofu apply

# grab credentials (gitignored)
tofu output -raw talosconfig > talosconfig
tofu output -raw kubeconfig  > kubeconfig
KUBECONFIG=$PWD/kubeconfig kubectl get nodes
# convenience: `devbox run k9s` (from repo root) opens k9s on this kubeconfig
```

> First-apply ordering gotcha: enabling `bgpControlPlane` via Helm does **not** auto-register
> the Cilium BGP CRDs, so `cilium-bgp.tf`'s `kubernetes_manifest` resources can fail on a cold
> apply. If so, `kubectl -n kube-system rollout restart deploy/cilium-operator` (registers the
> CRDs) and re-`apply`.

## Secrets

`talos_machine_secrets`, `talosconfig`, `kubeconfig`, and the Proxmox token are secret.
`*.tfstate*`, `*.tfvars`, `kubeconfig`, `talosconfig` are gitignored. Before this repo goes
public, the token + any state must be handled per `../PUBLISH-CHECKLIST.md` (SOPS for anything
that must live in git).

## Done

- **Phase 1** — 3-node Talos cluster on Proxmox, all `Ready`; Cilium CNI as a Helm release
  (boot-from-git); kube-proxy-free (Talos `proxy.disabled` + Cilium `kubeProxyReplacement`).
- **Service exposure** — Cilium BGP ↔ OPNsense FRR; LoadBalancer VIPs from `192.168.40.0/24`
  routed on the LAN (replaces NodePort/MetalLB). OPNsense side as code in `../ansible/`.
- **Phase 2** — Home Assistant deployed; reachable on `http://192.168.40.10:8123`.

## Not included yet (next steps)

- Remote/encrypted state backend (currently local state).
- Home Assistant `/config` → object-storage (S3) backup per ROADMAP (Longhorn covers in-cluster
  replication, not off-cluster DR).
- Cloudflare Tunnel for remote access (`../docs/cloudflare.md`).
- GitOps (ArgoCD/Flux) for workloads; Civo cloud-burst.
