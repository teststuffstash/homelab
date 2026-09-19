# TEMPORARY rehearsal resource. Destroy and remove this file after the v1.13.2 -> v1.13.10
# control-plane upgrade proof. It is intentionally outside var.nodes/talos.tf, so it cannot join
# the homelab cluster or share its machine secrets.
resource "proxmox_virtual_environment_vm" "cp_upgrade_lab" {
  provider  = proxmox.nx02
  name      = "cp-upgrade-lab"
  vm_id     = 8198
  node_name = var.nx02_node
  tags      = ["lab", "talos"]

  agent { enabled = true }
  cpu {
    cores   = 2
    sockets = 1
    type    = "host"
  }
  memory { dedicated = 4096 }
  disk {
    datastore_id = var.nx02_datastore_vms
    file_id      = proxmox_download_file.talos_nx02["plain-v1.13.2"].id
    interface    = "scsi0"
    size         = 20
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }
  network_device { bridge = var.network_bridge }
  operating_system { type = "l26" }
  initialization {
    datastore_id = var.nx02_datastore_vms
    ip_config {
      ipv4 {
        address = "192.168.2.65/24"
        gateway = var.gateway
      }
    }
  }
}
