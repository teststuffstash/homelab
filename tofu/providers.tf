# Proxmox-specific. This is the ONLY file that ties the cluster to this hardware.
# For a DR rebuild on other infra (e.g. AWS), swap proxmox.tf + this provider for
# the equivalent; talos.tf (the cluster definition) stays unchanged.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint  # e.g. https://192.168.2.3:8006/
  api_token = var.proxmox_api_token # "user@realm!tokenid=uuid" — via TF_VAR_proxmox_api_token / SOPS
  insecure  = var.proxmox_insecure  # true for the default self-signed cert

  # bpg needs SSH to the node for disk-image import (runs qemu-img on the host).
  # Key lives outside the repo at ~/.claude/homelab-pve-ssh/ (persisted); authorize
  # its .pub in pve root's authorized_keys. No Proxmox API exists to inject this —
  # it's the one-time root-of-trust seed.
  ssh {
    agent       = false
    username    = "root"
    private_key = file(var.proxmox_ssh_private_key_file)
  }
}

# The SECOND hypervisor (ROADMAP §Hardware strategy). nx-02 is the other node of the NX-6035-G5
# twin; it runs its own Proxmox and its own API token, so it needs its own provider instance —
# bpg has no per-resource endpoint. Nodes pick their hypervisor with `hypervisor` in var.nodes
# (default "pve"); the alias is wired in tofu/nx02.tf. Same SSH seed key as pve: authorized in
# nx-02 root's authorized_keys the same one-time way.
provider "proxmox" {
  alias     = "nx02"
  endpoint  = var.nx02_endpoint
  api_token = var.nx02_api_token # KeePass `nx-02-api-token-tofu`; via TF_VAR_nx02_api_token / main.tfvars
  insecure  = var.proxmox_insecure

  ssh {
    agent       = false
    username    = "root"
    private_key = file(var.proxmox_ssh_private_key_file)
  }
}

provider "talos" {}
