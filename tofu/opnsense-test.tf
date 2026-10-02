# OPNsense test VM on nx-02 (FU-297) — a throwaway router that validates router-config PRs
# (ansible/opnsense-*.yml) against a REAL OPNsense API instead of `--check` against a stub.
# Build + bootstrap: docs/opnsense-test-vm.md; per-run use: scripts/opnsense-test-vm.sh (the harness).
#
# Shape: net0 = LAN on an ISOLATED bridge with no physical port (its DHCP, HAProxy VIPs and
# Unbound serve nothing real); net1 = WAN on vmbr0 with its own inventory IP — the management
# path (API + SSH) and the egress for firmware/plugin installs. Its FRR is kept off the real
# Cilium peers by the seeded config (outbound TCP 179 blocked on WAN), not by anything here.
#
# ⚠ TOFU OWNS THE HARDWARE, NOT THE GUEST. The disk is born from the upstream nano image, and
# `scripts/opnsense-test-vm-bootstrap.sh bootstrap` seeds config.xml through OPNsense's own config
# importer on the FIRST boot (secrets from the wallet, never in git or in this state). So the
# VM is created STOPPED and tofu never touches its power state again (`started` ignored): a
# first boot without the seed would write the factory config.xml and the importer never offers
# itself again — the bootstrap refuses and tells you to recreate the disk.

variable "opnsense_test_vm_id" {
  type    = number
  default = 9110
}

variable "opnsense_test_wan_ip_cidr" {
  description = "opnsense-test's WAN (management) IP on vmbr0 — the .51–.99 servers range after ci-runner-02 (.66), docs/ip-plan.md; inventory entry in machines/machines.yaml."
  type        = string
  default     = "192.168.2.67/24"
}

variable "opnsense_test_lan_bridge" {
  description = "The isolated LAN bridge on nx-02 — NO bridge port and no host address, so nothing but the test VM is on it. ⚠ Never add eno2 here: it is reserved for a future WAN passthrough."
  type        = string
  default     = "vmbr1"
}

variable "opnsense_test_nano_version" {
  description = "The upstream nano image the disk is BORN from (a birth seed, like the Talos images — ignored after create). The bootstrap updates the guest to the prod series' current patch (its SERIES); upstream publishes one nano per major (26.7) plus the odd point release."
  type        = string
  default     = "26.7"
}

# The isolated segment. A new host bridge is a host network change: Proxmox rewrites
# /etc/network/interfaces and runs `ifreload -a` (ifupdown2 applies only the diff; vmbr0 is
# untouched) — still, apply it inside a maintenance window: nx-02 carries cp-02.
resource "proxmox_network_linux_bridge" "opnsense_test_lan" {
  provider  = proxmox.nx02
  node_name = var.nx02_node
  name      = var.opnsense_test_lan_bridge
  comment   = "opnsense-test LAN - isolated, no ports (FU-297)"
}

resource "proxmox_download_file" "opnsense_nano_nx02" {
  provider                = proxmox.nx02
  content_type            = "iso"
  datastore_id            = var.datastore_images
  node_name               = var.nx02_node
  file_name               = "OPNsense-${var.opnsense_test_nano_version}-nano-amd64.img"
  url                     = "https://pkg.opnsense.org/releases/${var.opnsense_test_nano_version}/OPNsense-${var.opnsense_test_nano_version}-nano-amd64.img.bz2"
  decompression_algorithm = "bz2"
  overwrite               = false
}

resource "proxmox_virtual_environment_vm" "opnsense_test" {
  provider  = proxmox.nx02
  name      = "opnsense-test"
  vm_id     = var.opnsense_test_vm_id
  node_name = var.nx02_node
  tags      = sort(["opnsense", "test"])

  # Created stopped; the bootstrap owns the first boot (header). on_boot=false: a host reboot
  # must not boot an unseeded disk, and nothing depends on this VM being up.
  started = false
  on_boot = false

  cpu {
    # Small enough to sit inside one of nx-02's two sockets — no NUMA split needed (nx02.tf).
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
    # The nano image is 3 GB; rc grows the UFS root to the disk on the first boot
    # (the image ships the /.probe.for.growfs marker). Room for firmware updates + plugins.
    size        = 8
    file_format = "raw"
    discard     = "on"
    ssd         = true
  }

  # ORDER IS THE INTERFACE ASSIGNMENT: net0 → vtnet0 = LAN, net1 → vtnet1 = WAN (the seeded
  # config.xml names them so).
  network_device {
    bridge = proxmox_network_linux_bridge.opnsense_test_lan.name
  }

  network_device {
    bridge = var.network_bridge
  }

  # The nano image's PRIMARY console is serial — and the bootstrap drives the config importer
  # through this socket (`/var/run/qemu-server/<vmid>.serial0`).
  serial_device {}

  operating_system {
    type = "other"
  }

  lifecycle {
    # file_id: a birth seed (the Talos precedent, ADR-138). started: the bootstrap and the
    # rollback verb own power state.
    ignore_changes = [disk[0].file_id, started]
  }
}

# ── The rebuild DRILL's substrate (FU-297, docs/opnsense-test-vm.md §The rebuild drill) ────────
# The drill builds an OPNsense VM from nothing each week (scripts/opnsense-drill.sh — vmid 9199
# `opnsense-drill`, WAN 192.168.2.68), converges ALL router code, probes it from a throwaway
# container on its LAN, scores its config.xml against prod's, and destroys both. The VM and the
# container are the DRILL's (qm/pct, created and destroyed per run — a weekly create/destroy in
# tofu would be an apply loop against itself); only what outlives a run lives here.
#
# Its own isolated LAN bridge, not vmbr1: the drill's LAN is 192.168.1.1/24 like the test VM's,
# and two routers claiming one address on one segment collide (ARP for .1, two DHCP servers
# answering the probe). A second port-less bridge keeps the two segments apart with no VLAN
# plumbing and no change to vmbr1, which the PR-validation VM is using. Same host-network-change
# caveat as vmbr1: apply inside a maintenance window (nx-02 carries cp-02).
variable "opnsense_drill_lan_bridge" {
  description = "The drill's isolated LAN bridge on nx-02 — NO bridge port and no host address; only the drill VM and its probe container are on it (FU-297)."
  type        = string
  default     = "vmbr2"
}

resource "proxmox_network_linux_bridge" "opnsense_drill_lan" {
  provider  = proxmox.nx02
  node_name = var.nx02_node
  name      = var.opnsense_drill_lan_bridge
  comment   = "opnsense-drill LAN - isolated, no ports (FU-297)"
}

# The probe container's template (the fake BGP peer + the DHCP/DNS/TLS probes) — the same
# Debian 12 standard template the Matchbox LXC is built from (tofu/provisioning), here on nx-02.
resource "proxmox_download_file" "debian_lxc_nx02" {
  provider     = proxmox.nx02
  content_type = "vztmpl"
  datastore_id = var.datastore_images
  node_name    = var.nx02_node
  file_name    = "debian-12-standard_12.12-1_amd64.tar.zst"
  # Plain http is where Proxmox publishes it (pveam fetches the same URL); the sha512 is from
  # pveam's signed index (/var/lib/pve-manager/apl-info/download.proxmox.com on nx-02).
  url                = "http://download.proxmox.com/images/system/debian-12-standard_12.12-1_amd64.tar.zst"
  checksum           = "50c85eaaece677a3ebe01cc909b83872e9da2a22c29ae652838afce71e83222fdf40f6accecd7d52b180e912fc1f85ecdf7b3fc4d3027da4d865e509a9e76597"
  checksum_algorithm = "sha512"
  overwrite          = false
}
