# Bare-metal Talos workers (PXE-installed via Matchbox, NOT Proxmox VMs).
#
# Deliberately separate from var.nodes / proxmox.tf so adding metal never touches the
# VM cluster — these resources reuse the shared cluster secrets + endpoint only.
# Flow: box PXE-boots Talos (maintenance mode, DHCP-reserved IP) -> `tofu apply` pushes
# this worker config -> Talos installs to disk, reboots, joins the cluster.
# Install image with the Longhorn-required system extensions baked in
# (qemu-guest-agent + iscsi-tools + util-linux-tools). MUST be set or the install goes
# vanilla (no extensions) even when the PXE/USB boot image had them — keep in lockstep
# with the schematic used for the Matchbox assets / talos-usb ISO.
variable "talos_install_image" {
  type    = string
  default = "factory.talos.dev/installer/53513e54bb39202f35694412577a6bc53d484744d35a126e5d42ef34785c0d83:v1.13.2"
}

variable "metal_nodes" {
  description = "Bare-metal Talos worker nodes keyed by hostname."
  type = map(object({
    ip           = string # DHCP-reserved IP (maintenance-mode + ongoing node address)
    install_disk = string # target disk for the Talos install (NOT the optane cache)
    # Extra block devices to format+mount as Longhorn "fast" disks. Mounted UNDER
    # /var/lib/longhorn/ on purpose: longhorn-manager only host-mounts that path (with
    # Bidirectional propagation), so a disk anywhere else is invisible to it. Each becomes
    # /var/lib/longhorn/optane<N>; registered into Longhorn with tag "fast" (see
    # scripts/longhorn-register-optane.sh + the longhorn-fast StorageClass in longhorn.tf).
    optane_disks = optional(list(string), [])
  }))
  default = {
    # ThinkPad X240 — 500GB Crucial MX500 SATA SSD (confirmed via `talosctl get disks`)
    wk-metal-01 = { ip = "192.168.2.182", install_disk = "/dev/sda" }
    # ThinkPad X250 — 128GB SanDisk SDSSDHP1 SATA SSD (confirmed via `talosctl get disks`).
    # Laptop/compute tier like the X240: tainted ephemeral below, no Longhorn disk.
    wk-metal-02 = { ip = "192.168.2.183", install_disk = "/dev/sda" }
    # ThinkCentre Edge — 120GB Kingston SV300 (NOT sda=USB-boot, NOT nvme=Optane scratch).
    # Key == node name (from its DHCP-reservation hostname). Onboarded via USB ISO at Talos
    # v1.13.0; since upgraded in-place to v1.13.2 (matches cluster). Two Intel Optane M10 16GB
    # (nvme0n1/nvme1n1) → Longhorn fast tier (replica=1 scratch).
    thinkcentre = { ip = "192.168.2.53", install_disk = "/dev/sdc", optane_disks = ["/dev/nvme0n1", "/dev/nvme1n1"] }
    # HP desktop — 128GB SanDisk SATA SSD. Installs WITH extensions (install.image
    # above), so it joins Longhorn-ready. Power: aquarium plug (AC-restore flaky → WoL).
    hp-01 = { ip = "192.168.2.54", install_disk = "/dev/sda" }
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
  config_patches = concat(
    [yamlencode({
      machine = {
        install = {
          disk  = each.value.install_disk
          image = var.talos_install_image
        }
      }
    })],
    # Format + mount any extra disks (Optane) under /var/lib/longhorn so longhorn-manager
    # can see them. Talos partitions (GPT, full disk) + makes a filesystem + mounts.
    length(each.value.optane_disks) > 0 ? [yamlencode({
      machine = {
        disks = [for i, dev in each.value.optane_disks : {
          device     = dev
          partitions = [{ mountpoint = "/var/lib/longhorn/optane${i}" }]
        }]
      }
    })] : []
  )
}

# The ThinkPad X240 is the ephemeral/compute tier — not always-on, vanilla install (no
# Longhorn disk / iscsi). Taint it so stateful services (which tolerate nothing special)
# never schedule there; explicitly-tolerating workloads (e.g. future CI runners) still can.
resource "kubernetes_node_taint" "laptop" {
  metadata { name = "wk-metal-01" }
  taint {
    key    = "homelab.io/ephemeral"
    value  = "true"
    effect = "NoSchedule"
  }
}

# ThinkPad X250 — same ephemeral/compute tier as the X240. Applied after the node joins.
resource "kubernetes_node_taint" "laptop_x250" {
  metadata { name = "wk-metal-02" }
  taint {
    key    = "homelab.io/ephemeral"
    value  = "true"
    effect = "NoSchedule"
  }
}

resource "talos_machine_configuration_apply" "metal" {
  for_each = var.metal_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.metal[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
}
