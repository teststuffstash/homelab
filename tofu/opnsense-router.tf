# The CARP pair's router nodes (ADR-144, docs/router-move.md §The standing nodes): symmetric
# OPNsense VMs, WAN + LAN only, each managed at its own LAN address (its `ansible_host` for good,
# ansible/router-nodes/inventory.yml). Built BESIDE Big Data, which keeps `.1` until the cutover
# window — until then a node stands INERT on the LAN (the standby profile, group_vars
# `opnsense_standby`). This file: nx-02's node, then pve's — the same shape on each hypervisor.
#
# ⚠ TOFU OWNS THE HARDWARE, NOT THE GUEST — exactly as tofu/opnsense-test.tf: the disk is born from
# the nano image, `scripts/opnsense-router-node.sh build <node>` seeds config.xml through the
# config importer on the FIRST boot (identity carried from the newest FU-013 backup, never in git
# or this state). So the VM is created STOPPED and `started` is ignored. on_boot is false for a
# NEW node — a host reboot must not boot an unseeded disk — and flips true once the node is built,
# in the same change that lists its vmid for the hypervisor's kill switch
# (ansible/pve-router-killswitch.yml, armed before pve-guests starts anything). A trip sets
# onboot 0 on the host: that shows here as drift, and re-enabling is this apply, never automatic.
#
# The WAN: `eno2` (the I350's second port) is the only port of `vmbr3`, a bridge with NO host
# address; the VM's WAN is virtio on it (bridged, not passthrough — measured ~3× line rate, the
# operator's condition, router-move.md). The node spoofs Big Data's WAN MAC, so eno2 stays
# UNCABLED until the window: the build refuses carrier.

variable "opnsense_router_nx02_vm_id" {
  type    = number
  default = 9170
}

variable "opnsense_router_pve_vm_id" {
  type    = number
  default = 9171
}

variable "opnsense_router_wan_bridge" {
  description = "Each node's WAN bridge (the same name on both hypervisors) — the WAN NIC its only port, no host address (ADR-144). The rehearsal's runtime vmbr9 is a different, throwaway bridge."
  type        = string
  default     = "vmbr3"
}

# A host bridge is a host network change (ifreload -a applies the diff; vmbr0 untouched) — apply
# inside a maintenance window: nx-02 carries cp-02 and wk-04.
resource "proxmox_network_linux_bridge" "opnsense_router_wan" {
  provider  = proxmox.nx02
  node_name = var.nx02_node
  name      = var.opnsense_router_wan_bridge
  ports     = ["eno2"]
  comment   = "router node WAN - eno2 only, no address, UNCABLED until the cutover (ADR-144)"
}

resource "proxmox_virtual_environment_vm" "opnsense_router_nx02" {
  provider  = proxmox.nx02
  name      = "opnsense-nx02"
  vm_id     = var.opnsense_router_nx02_vm_id
  node_name = var.nx02_node
  tags      = sort(["opnsense", "router"])

  started = false
  on_boot = true # built + standing 2026-09-30 (#2141); kill switch host_vars nx-02-host.yml

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.nx02_datastore_vms
    file_id      = proxmox_download_file.opnsense_nano_nx02.id
    interface    = "scsi0"
    size         = 8
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  # ORDER IS THE INTERFACE ASSIGNMENT: net0 → vtnet0 = LAN, net1 → vtnet1 = WAN (the seed's
  # standing shape names them so, opnsense/test-vm/seed-shape.py --standing).
  network_device {
    bridge = var.network_bridge
    # Fixed + locally administered (02:…), = 192.168.2.70 in hex: the build's kill switch
    # (scripts/opnsense-router-node.sh) watches frames from this MAC before the VM ever boots.
    mac_address = "02:00:C0:A8:02:46"
    queues      = 2
  }

  network_device {
    bridge = proxmox_network_linux_bridge.opnsense_router_wan.name
    # firewall stays OFF: Proxmox's macfilter would drop the spoofed source MAC (router-move.md).
    firewall = false
    queues   = 2
  }

  serial_device {}

  operating_system {
    type = "other"
  }

  lifecycle {
    ignore_changes = [disk[0].file_id, started]
  }
}

# ---- pve's node (ADR-144 (2)) — the same shape; its WAN is the TP-LINK TG-3468 (RTL8168, x1) fitted
# 2026-09-30, `enp6s0`, bridged (virtio in the VM, never passthrough — router-move.md). The onboard
# RTL8168 is pinned `nic0` (vmbr0), so enp6s0 is the card by MAC, not by slot order. UNCABLED until
# the window, like eno2.

resource "proxmox_network_linux_bridge" "opnsense_router_wan_pve" {
  node_name = var.proxmox_node
  name      = var.opnsense_router_wan_bridge
  ports     = ["enp6s0"]
  comment   = "router node WAN - enp6s0 only, no address, UNCABLED until the cutover (ADR-144)"
}

resource "proxmox_download_file" "opnsense_nano_pve" {
  content_type            = "iso"
  datastore_id            = var.datastore_images
  node_name               = var.proxmox_node
  file_name               = "OPNsense-${var.opnsense_test_nano_version}-nano-amd64.img"
  url                     = "https://pkg.opnsense.org/releases/${var.opnsense_test_nano_version}/OPNsense-${var.opnsense_test_nano_version}-nano-amd64.img.bz2"
  decompression_algorithm = "bz2"
  overwrite               = false
}

resource "proxmox_virtual_environment_vm" "opnsense_router_pve" {
  name      = "opnsense-pve"
  vm_id     = var.opnsense_router_pve_vm_id
  node_name = var.proxmox_node
  tags      = sort(["opnsense", "router"])

  started = false
  # on_boot: latched OFF 2026-10-02 by the kill switch (a relayed, not served, DHCP reply — the
  # hypervisor's unicast flooding, explained + fixed 2026-10-08, docs/router-move.md). Back to true
  # for window 2 (ADR-145): the node is the CARP BACKUP; kill switch host_vars pve-host.yml.
  on_boot = true

  cpu {
    cores = 2
    type  = "host"
  }

  # pve is booked ~61 of 62.7 GiB (cp-01, wk-01..03, ci-runner-01; balloon off) — resident ~26 GiB.
  # 2 GiB here, symmetric with nx-02's; the booked-vs-physical gap is FU-289's class (RAM).
  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = var.datastore_vms
    file_id      = proxmox_download_file.opnsense_nano_pve.id
    interface    = "scsi0"
    size         = 8
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  # net0 → vtnet0 = LAN, net1 → vtnet1 = WAN (as nx-02's).
  network_device {
    bridge = var.network_bridge
    # = 192.168.2.71 in hex, locally administered.
    mac_address = "02:00:C0:A8:02:47"
    queues      = 2
  }

  network_device {
    bridge   = proxmox_network_linux_bridge.opnsense_router_wan_pve.name
    firewall = false
    queues   = 2
  }

  serial_device {}

  operating_system {
    type = "other"
  }

  lifecycle {
    ignore_changes = [disk[0].file_id, started]
  }
}
