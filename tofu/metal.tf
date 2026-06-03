# Bare-metal Talos workers (PXE-installed via Matchbox, NOT Proxmox VMs).
#
# Deliberately separate from var.nodes / proxmox.tf so adding metal never touches the
# VM cluster — these resources reuse the shared cluster secrets + endpoint only.
# Flow: box PXE-boots Talos (maintenance mode, DHCP-reserved IP) -> `tofu apply` pushes
# this worker config -> Talos installs to disk, reboots, joins the cluster.
variable "metal_nodes" {
  description = "Bare-metal Talos worker nodes keyed by hostname."
  type = map(object({
    ip           = string # DHCP-reserved IP (maintenance-mode + ongoing node address)
    install_disk = string # target disk for the Talos install (NOT the optane cache)
  }))
  default = {
    # ThinkPad X240 — 500GB Crucial MX500 SATA SSD (confirmed via `talosctl get disks`)
    wk-metal-01 = { ip = "192.168.2.182", install_disk = "/dev/sda" }
  }
}

data "talos_machine_configuration" "metal" {
  for_each = var.metal_nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = trimprefix(var.kubernetes_version, "v")
  talos_version      = var.talos_version

  # Hostname comes from the DHCP reservation (dnsmasq sends it), same as the VMs get
  # theirs from nocloud — setting it here too makes Talos reject the config as a conflict.
  config_patches = [
    yamlencode({
      machine = {
        install = { disk = each.value.install_disk }
      }
    })
  ]
}

resource "talos_machine_configuration_apply" "metal" {
  for_each = var.metal_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.metal[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
}
