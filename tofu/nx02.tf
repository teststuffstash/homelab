# The SECOND hypervisor's VMs (nx-02 — NX-6035-G5 node 2, ROADMAP §Hardware strategy).
#
# Deliberately a near-copy of proxmox.tf + the proxmox_download_file pair in image.tf rather than
# a shared module: a provider instance cannot be selected per for_each key, so a node on the other
# hypervisor needs its own resource block whatever the factoring. Keeping the two blocks literal
# makes the drift visible in review; the SCHEMATICS (talos_image_factory_*) are shared, so both
# hypervisors always run byte-identical images.
#
# The cluster layer (talos.tf) never learns which box a node runs on — it spans all of var.nodes.

resource "proxmox_download_file" "talos_nx02" {
  for_each                = local.vm_images # the same (schematic, role-version) set as pve (image.tf)
  provider                = proxmox.nx02
  content_type            = "iso"
  datastore_id            = var.datastore_images
  node_name               = var.nx02_node
  file_name               = "talos-${each.value.version}-${each.value.longhorn ? "longhorn-" : ""}nocloud-amd64.img"
  url                     = data.talos_image_factory_urls.vm[each.key].urls.disk_image
  decompression_algorithm = "zst"
  overwrite               = false
}


resource "proxmox_virtual_environment_vm" "nx02_node" {
  provider = proxmox.nx02
  for_each = local.nx02_nodes

  name      = each.key
  vm_id     = each.value.vm_id
  node_name = var.nx02_node
  tags      = sort(["talos", each.value.role])

  agent {
    enabled = true
  }

  cpu {
    # nx-02 is DUAL-socket (2 × E5-2640 v4, 10C/20T each, 32 GiB of RDIMMs per socket) where pve is
    # single-socket — the one place the two VM blocks must differ. A flat 16-vCPU single-socket VM
    # cannot fit inside one physical socket, so QEMU spreads its threads and its 32 GiB across both
    # NUMA nodes while the guest sees a uniform machine and schedules as if memory were local.
    # sockets=2 + numa=true make the guest topology match the host's, so Linux keeps a task's memory
    # on its own node. `cores` is therefore PER SOCKET here; the node's total is cores × sockets.
    cores   = each.value.cores / 2
    sockets = 2
    numa    = true
    type    = "host"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    # The Micron NVMe thin pool, never the WD spinner `local-lvm` — this tier hosts the
    # containerd image store and a VM root, both of which the 5400-rpm disk would throttle.
    datastore_id = var.nx02_datastore_vms
    # Same two axes as proxmox.tf (image.tf `local.vm_seed_key`): `longhorn` means "this VM
    # TOUCHES Longhorn volumes" (iscsi-tools + util-linux-tools in the image), not "it serves
    # replicas"; the role picks the version. ⚠ Flipping either on a live VM plans NOTHING now —
    # `file_id` is ignored below (ADR-138); see the longer note in proxmox.tf.
    file_id     = proxmox_download_file.talos_nx02[local.vm_seed_key[each.key]].id
    interface   = "scsi0"
    size        = each.value.disk_gb
    file_format = "raw"
    # discard=on so guest TRIMs reach the thin pool (the 2026-08-18 pve lesson — the provider
    # default `ignore` let every byte ever written stay allocated forever).
    discard = "on"
    ssd     = true
  }

  network_device {
    bridge = var.network_bridge
  }

  dynamic "serial_device" {
    for_each = each.value.serial ? [1] : []
    content {}
  }

  # PCIe passthrough of a host device (variables.tf `hostpci_mapping` carries the why). Only wk-04 uses
  # it today: the WD SN530 at 0000:82:00.0, so the guest sees a REAL NVMe and its Longhorn disk is
  # not a slice of the nvme-thin pool.
  # ⚠ `pcie = false`, and that is DELIBERATE, not an oversight. `pcie = true` requires the **q35**
  # machine type; these VMs declare no `machine` at all, so they run Proxmox's default **i440fx**
  # (read live 2026-09-24: `qm config 8114` has no `machine:` line). Setting pcie=true on i440fx
  # makes the guest refuse to start — and it would have done so on the very stop/start this
  # passthrough needs. The device still passes through fine on the legacy PCI bus; Linux binds the
  # nvme driver either way.
  # Switching the VM to q35 is NOT the cheap fix: it changes the guest's PCI topology and can
  # rename the NIC, and these VMs take their static IP from the nocloud datasource — a renamed
  # interface is a node that comes back unaddressed. If a future device genuinely needs PCIe
  # semantics, that is its own change with its own window.
  # ⚠ hostpci is NOT hot-pluggable: applying or changing it needs a full VM stop/start, so it rides
  # a `node-maintenance` window. A guest-initiated reboot keeps the qemu process and never picks up
  # pending hardware — the same trap the `serial` flag's note above records.
  # ⚠ A MAPPING NAME, NOT A RAW BDF — this is a Proxmox permission boundary, found by applying
  # (2026-09-24): `id = "0000:82:00.0"` fails with HTTP 500 *"only root can set 'hostpci0' config
  # for non-mapped devices"*. Proxmox lets only `root@pam` name raw PCI addresses; a non-root
  # identity may attach a device only through a cluster mapping someone else declared.
  # We took the RESTRAINED half of that deal deliberately (operator, 2026-09-24): the `TerraformProv`
  # role gained `Mapping.Audit` + `Mapping.Use` and **NOT `Mapping.Modify`**, so this token can
  # attach the mappings a human declared but cannot invent new ones. `Mapping.Modify` would let the
  # automation identity expose ANY host device to ANY guest — a host-compromise primitive, and a
  # step change from its otherwise VM-scoped power. The mapping itself is therefore a Phase-0
  # bootstrap step beside the role, the user and the SSH seed (tofu/README.md).
  dynamic "hostpci" {
    for_each = each.value.hostpci_mapping == null ? [] : [each.value.hostpci_mapping]
    content {
      device  = "hostpci0"
      mapping = hostpci.value
      # pcie=false: these VMs declare no `machine`, so they run Proxmox's default i440fx, and
      # pcie=true on i440fx makes the guest refuse to start (read live: `qm config 8114` has no
      # `machine:` line). The device passes through fine on the legacy PCI bus. Moving the VM to
      # q35 is NOT the cheap fix — it changes the guest's PCI topology and can rename the NIC, and
      # these VMs take their static IP from the nocloud datasource, so a renamed interface is a
      # node that comes back unaddressed.
      pcie = false
    }
  }

  operating_system {
    type = "l26"
  }

  # ⚠ THE DISK IMAGE IS A BIRTH SEED, NOT A DECLARATION OF WHAT THE NODE RUNS (ADR-138, FU-263).
  # Same reasoning as the pve nodes — the long version is in proxmox.tf. `file_id` names the image
  # this disk was CLONED FROM; the running substrate is declared by `machine.install.image`
  # (talos.tf) and moved in place by the upgrade verb. `plan` no longer sees a schematic change
  # here either; `mgmt_node_drift{axis="schematic"}` does (FU-235).
  lifecycle {
    ignore_changes = [disk[0].file_id]
  }

  # Static IP handed to Talos via the nocloud datasource — same as the pve nodes. ⚠ `talosctl
  # upgrade` one of these ONLY with the platform-correct installer: the generic
  # ghcr.io/siderolabs/installer reinstalls it as `platform: metal`, the nocloud datasource is
  # never read again, and the node rejoins as a DHCP-addressed ghost. With the matching
  # nocloud-installer URL it upgrades in place, IP and hostname intact (ADR-014 as amended
  # 2026-09-18; `devbox run node-maintenance order` picks the image for you).
  initialization {
    datastore_id = var.nx02_datastore_vms

    ip_config {
      ipv4 {
        address = each.value.ip_cidr
        gateway = var.gateway
      }
    }
  }
}
