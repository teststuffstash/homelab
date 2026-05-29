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

provider "talos" {}
