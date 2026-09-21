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
    # schematic (mount OR serve, see variables.tf), the role picks the Talos version. ⚠ Flipping
    # either on a live VM NO LONGER plans anything — `file_id` is ignored below (ADR-138), because
    # it is a birth seed. A version change is delivered by the upgrade verb; a SCHEMATIC change is
    # seen only by `mgmt_node_drift{axis="schematic"}` (FU-235) and rebuilt by a planned `-replace`
    # that you read first.
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

  # ⚠ THE DISK IMAGE IS A BIRTH SEED, NOT A DECLARATION OF WHAT THE NODE RUNS (ADR-138, FU-263).
  # `file_id` names the image this VM's disk was CLONED FROM at creation. The provider treats it
  # as a live attribute and forces replacement when it changes, so the routine act of moving the
  # Talos version planned two control-plane VMs destroyed and rebuilt — while ADR-014 (as amended
  # 2026-09-18, and proven on a disposable nx-02 VM on 09-19) says a nocloud VM upgrades IN PLACE
  # like metal, provided the installer matches on platform, schematic and version. The two models
  # disagreed, and the pending replace they left behind is the FU-248 landmine.
  #
  # So the running substrate is declared where it is actually read — `machine.install.image` in
  # talos.tf, the same URL `node_install_targets` hands the upgrade verb — and this attribute goes
  # back to meaning what the provider can honestly promise: what a NEW VM boots the first time.
  # A VM created after a version bump still comes up on the new image.
  #
  # What this costs: `plan` no longer notices a SCHEMATIC change either (flipping `longhorn` on a
  # live VM), because both axes live in this one string. That is why FU-235's declared-vs-live
  # diff had to land first — `mgmt_node_drift{axis="schematic"}` is the detector now. To rebuild a
  # VM on a new image deliberately, plan it with `-replace` and read the plan (mgmt-tf, FU-248).
  lifecycle {
    ignore_changes = [disk[0].file_id]
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
