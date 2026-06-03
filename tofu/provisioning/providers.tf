# Proxmox provider for the provisioning plane. SEPARATE root module / state from
# ../  (the cluster) on purpose: a `tofu destroy` of the cluster must NOT take the
# provisioner (Matchbox) with it — the provisioner is what reinstalls bare metal,
# so it has to outlive any cluster wipe (ROADMAP "boot from git" invariant).
provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token # "user@realm!tokenid=uuid" — via TF_VAR_proxmox_api_token
  insecure  = var.proxmox_insecure

  # bpg uses SSH to the node for some container operations (root-of-trust seed key,
  # same one the cluster module uses). Authorize its .pub in pve root authorized_keys.
  ssh {
    agent       = false
    username    = "root"
    private_key = file(var.proxmox_ssh_private_key_file)
  }
}
