# Proxmox VMs on `pve` — the hardware-specific layer. One VM per var.nodes entry whose
# `hypervisor` is "pve" (the default). Each boots from a clone of the imported Talos disk image.
# The nodes on the second hypervisor are the same shape in tofu/nx02.tf.
resource "proxmox_virtual_environment_vm" "node" {
  for_each = local.pve_nodes

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
    # The image follows two axes (image.tf `local.vm_image_key`): the `longhorn` flag picks the
    # schematic (mount OR serve, see variables.tf), the role picks the Talos version. Flipping
    # either on a live VM changes file_id, i.e. plans a REPLACE of the node, not an in-place edit.
    file_id     = proxmox_download_file.talos[local.vm_image_key[each.key]].id
    interface   = "scsi0"
    size        = each.value.disk_gb
    file_format = "raw"
    # discard=on (2026-08-18): the provider default was `ignore`, so guest TRIMs NEVER reached
    # the LVM thin pool — every byte ever written stayed allocated forever (pool hit its 81%
    # autoextend threshold with 1G VG free and refused wk-03's volumes; wk-01 held 65G real for
    # a mostly-stateless worker). Takes effect at the next VM power-cycle; reclaim = fstrim in
    # the guest afterwards.
    discard = "on"
    ssd     = true
  }

  network_device {
    bridge = var.network_bridge
  }

  # Serial console for the nodes flagged `serial` (variables.tf) — the guest kernel already logs
  # to ttyS0; the socket is tailed on pve by ansible/roles/pve-serial-log.
  dynamic "serial_device" {
    for_each = each.value.serial ? [1] : []
    content {}
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
