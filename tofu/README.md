# `tofu/` — Phase 1: Talos k8s cluster on Proxmox

Provisions a Talos Linux Kubernetes cluster as VMs on the Proxmox host (`pve`,
`192.168.2.3`). Implements ROADMAP.md Phase 1.

> **Status: scaffold, not yet applied.** Validated with `tofu validate` but never
> `apply`-ed against the real host. Run `tofu plan` and review before `apply`.

## Pinned versions

| Thing | Version |
|---|---|
| Talos Linux | `v1.13.2` (Kubernetes `v1.36.1`) |
| `bpg/proxmox` | `~> 0.107` |
| `siderolabs/talos` | `~> 0.11` |

Provider hashes are pinned in `.terraform.lock.hcl` (committed, on purpose).

## Layout (why it's split this way)

- `talos.tf` + `image.tf` + `outputs.tf` — **provider-agnostic cluster layer**. In a
  DR rebuild onto other infra (e.g. AWS EC2), these are reused unchanged.
- `proxmox.tf` + `providers.tf` — **the only hardware-specific files**. Swap these for
  the DR target. (Boot-from-git invariant: recovery shouldn't depend on this hardware.)
- `variables.tf` / `locals.tf` / `terraform.tfvars.example` — inputs. `nodes` is a map
  (deterministic `for_each`); keep it sorted by key.

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

> If disk-image import fails with a permissions error, the simple fallback is a
> `root@pam` token (`pveum user token add root@pam tofu --privsep 0`) and/or
> enabling the `ssh {}` block in `providers.tf`.

## Use

```bash
devbox shell                                   # toolchain (tofu/talosctl/...) from ../devbox.json
cp terraform.tfvars.example terraform.tfvars   # edit IPs/specs (must be free IPs)
tofu init
tofu validate
tofu plan
tofu apply

# grab credentials (gitignored)
tofu output -raw talosconfig > talosconfig
tofu output -raw kubeconfig  > kubeconfig
KUBECONFIG=$PWD/kubeconfig kubectl get nodes
```

## Secrets

`talos_machine_secrets`, `talosconfig`, `kubeconfig`, and the Proxmox token are
secret. `*.tfstate*`, `*.tfvars`, `kubeconfig`, `talosconfig` are gitignored. Before
this repo goes public, the token + any state must be handled per `../PUBLISH-CHECKLIST.md`
(SOPS for anything that must live in git).

## Not included yet (next steps)

- **CNI**: Talos ships without one by default. Add Cilium (inline manifests / Helm) —
  ties to the Gateway API direction in `../CONTEXT.md`.
- Remote/encrypted state backend (currently local state).
- Promotion of `nodes` IPs to OPNsense reservations as code (`oxlorg.opnsense`).
