# `tofu/` — the main cluster root (Talos on Proxmox + bare metal, and the platform substrate)

Provisions the Talos Linux Kubernetes cluster (VMs on the Proxmox host `pve` `192.168.2.3` +
bare-metal workers), installs Cilium as the CNI, exposes services on the LAN via Cilium BGP, and
carries the platform substrate that ArgoCD can't manage for itself (ADR-005): storage, monitoring,
Garage, Forgejo, ArgoCD + its bootstrap seeds. Grew out of ROADMAP.md Phases 1–2.

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
  service routing). (Stateful services are on **Longhorn** now — the old `/var/mnt/*` hostPath
  kubelet `extraMounts` were removed; Longhorn uses `/var/lib/longhorn`.)
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
- `unifi.tf` — UniFi Network Application + MongoDB on Longhorn (replaces the previous Docker controller);
  `LoadBalancer` VIP `192.168.40.12` (mixed TCP/UDP). **Applied & live**; image pinned by digest.
- `longhorn.tf` — Longhorn storage (default StorageClass, replicated) + a `longhorn-fast`
  node-local tier on the ThinkCentre's Optane.
- `metal.tf` — bare-metal Talos workers (PXE/USB-installed, not Proxmox VMs), incl. the
  `HostnameConfig` hostname pinning; see `../docs/provisioning.md`.
- `monitoring.tf` — Prometheus + Grafana + Alertmanager (BGP VIPs `.13`/`.11`/`.14`);
  `dashboards/` holds the provisioned Grafana dashboard JSON.
- `metrics-server.tf` — `kubectl top` / HPA.
- `argocd.tf` — ArgoCD install + bootstrap secret seeds + the two app-of-apps roots
  (`../argocd/README.md`); `infisical/` (sub-root) declares the Infisical project + ESO identity.
- `garage.tf` — Garage S3 object store (vendored chart `charts/garage/`; `../docs/garage.md`).
- `forgejo.tf` / `forgejo-pg.tf` / `forgejo-runner.tf` — Forgejo (CNPG-backed) + the Tier-B
  `act_runner` (`../docs/ci.md`).
- `ci-runner.tf` — the Proxmox VM GitHub Actions runner `ci-runner-01` @ `.2.55` (ADR-082).
- `outputs.tf` — `talosconfig`, `kubeconfig`, `cluster_endpoint`, service URLs, admin credentials.

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
> `terraform.tfvars`) — **burnable: rotate to a scoped `tofu@pve` token (FU-004)** (it was never
> committed). The SSH key bpg uses for disk import
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
`*.tfstate*`, `*.tfvars`, `kubeconfig`, `talosconfig` are gitignored (never committed). Secret
values live in the KeePass wallet / Infisical (`../docs/secrets.md`, ADR-062) — nothing secret
goes in git.

## Done

- **Phase 1** — 3-node Talos cluster on Proxmox, all `Ready`; Cilium CNI as a Helm release
  (boot-from-git); kube-proxy-free (Talos `proxy.disabled` + Cilium `kubeProxyReplacement`).
- **Service exposure** — Cilium BGP ↔ OPNsense FRR; LoadBalancer VIPs from `192.168.40.0/24`
  routed on the LAN (replaces NodePort/MetalLB). OPNsense side as code in `../ansible/`.
- **Phase 2** — Home Assistant deployed; `http://192.168.40.10:8123`, HTTPS `homeassistant.teststuff.net`
  (LAN HAProxy) and `ha.teststuff.net` (remote, via the Cloudflare root).

## Related roots

- **`../tofu/cloudflare/`** + **`../tofu/cloudflare-token/`** — remote access (Cloudflare Tunnel +
  mTLS, **live**); separate roots/state. See `../docs/cloudflare.md`.
- **`../tofu/provisioning/`** — Matchbox PXE LXC (separate root/state); see `../docs/provisioning.md`.
- **`../tofu/github/`** — GitHub repos, branch-protection rulesets + agent labels (separate root;
  applied outside the jail with an admin PAT — see its README).
- **`tofu/infisical/`** — Infisical project + `eso-reader` identity (separate state; `apply.sh`).

## Not included yet (next steps)

- FU-012 — remote/encrypted state backend (currently local state).
- FU-013 — Home Assistant `/config` → object-storage (S3) backup (Longhorn covers in-cluster
  replication, not off-cluster DR).
