# Proxmox-specific. This is the ONLY file that ties the cluster to this hardware.
# For a DR rebuild on other infra (e.g. AWS), swap proxmox.tf + this provider for
# the equivalent; talos.tf (the cluster definition) stays unchanged.
provider "proxmox" {
  endpoint  = var.proxmox_endpoint  # e.g. https://192.168.2.3:8006/
  api_token = var.proxmox_api_token # "user@realm!tokenid=uuid" — via TF_VAR_proxmox_api_token / SOPS
  insecure  = var.proxmox_insecure  # true for the default self-signed cert

  # Some bpg operations (disk image import, snippets) require SSH to the node.
  # Uncomment and run `ssh-add` for the pve root key if `tofu apply` asks for it.
  # ssh {
  #   agent    = true
  #   username = "root"
  # }
}

provider "talos" {}
