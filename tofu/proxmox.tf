# Proxmox VMs — the hardware-specific layer. One VM per node in var.nodes.
# Each boots from a clone of the imported Talos disk image.
resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = var.proxmox_node
  tags      = sort(["talos", each.value.role])

  agent {
    enabled = true
  }

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = var.datastore_vms
    # storage-tier VMs (longhorn=true) boot the iscsi/util-linux image; others the base one
    file_id     = each.value.longhorn ? proxmox_download_file.talos_longhorn.id : proxmox_download_file.talos.id
    interface   = "scsi0"
    size        = each.value.disk_gb
    file_format = "raw"
  }

  network_device {
    bridge = var.network_bridge
  }

  operating_system {
    type = "l26"
  }

  # Static IP handed to Talos via the nocloud datasource.
  initialization {
    datastore_id = var.datastore_vms

    ip_config {
      ipv4 {
        address = each.value.ip_cidr
        gateway = var.gateway
      }
    }
  }
}
