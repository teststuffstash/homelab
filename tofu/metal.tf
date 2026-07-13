# Bare-metal Talos workers (PXE-installed via Matchbox, NOT Proxmox VMs).
#
# Deliberately separate from var.nodes / proxmox.tf so adding metal never touches the
# VM cluster — these resources reuse the shared cluster secrets + endpoint only.
# Flow: box PXE-boots Talos (maintenance mode, DHCP-reserved IP) -> `tofu apply` pushes
# this worker config -> Talos installs to disk, reboots, joins the cluster.
# Install image = the **metal** schematic (image.tf): iscsi-tools + util-linux-tools for
# Longhorn, but NO qemu-guest-agent (that VM-only extension hangs the boot on physical HW —
# root cause of the metal flapping, see image.tf). MUST be set or the install goes vanilla.
# Changing it requires a reinstall (reset → maintenance → `tofu apply -replace`).
locals {
  talos_install_image = data.talos_image_factory_urls.metal.urls.installer
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
    # Pin the hostname via a HostnameConfig patch (see below). Default true. Set false for a node
    # that has NOT yet been reinstalled with the pinned config — otherwise a plain `tofu apply`
    # would push the hostname change to the *running* node and ghost it (install-time only).
    pin_hostname = optional(bool, true)
    # Install the metal_kata image (Kata Containers runtime — SLSA Phase-3 / agent-CI microVMs,
    # image.tf) and label the node kata-capable (the `kata` RuntimeClass in kata.tf selects on
    # it). Requires VT-x enabled in BIOS. Install-time only, like everything in install.image.
    kata = optional(bool, false)
  }))
  default = {
    # ThinkPad X240 — 500GB Crucial MX500 SATA SSD (confirmed via `talosctl get disks`)
    wk-metal-01 = { ip = "192.168.2.182", install_disk = "/dev/sda" }
    # ThinkPad X250 — 128GB SanDisk SDSSDHP1 SATA SSD (confirmed via `talosctl get disks`).
    # Laptop/compute tier like the X240: tainted ephemeral below, no Longhorn disk.
    wk-metal-02 = { ip = "192.168.2.183", install_disk = "/dev/sda" }
    # ThinkCentre Edge — 120GB Kingston SV300S3 SATA SSD. ⚠️ Device name is enumeration-order
    # dependent: it's /dev/sdb when PXE-booting with NO USB stick plugged (the steady state), but
    # was /dev/sdc during the original USB-ISO onboarding (USB took sda). PXE now works reliably
    # since the NIC cable was fixed (2026-06-11) — was "flaky PXE" purely because the marginal
    # link timed out netboot. (A diskSelector by serial/wwid would be more robust than /dev/sdX.)
    # Two Intel Optane M10 16GB (nvme0n1/nvme1n1) → Longhorn fast tier (replica=1 scratch).
    thinkcentre = { ip = "192.168.2.53", install_disk = "/dev/sdb", optane_disks = ["/dev/nvme0n1", "/dev/nvme1n1"], pin_hostname = true }
    # HP desktop — 128GB SanDisk SATA SSD. Installs WITH extensions (install.image
    # above), so it joins Longhorn-ready. Power: aquarium plug (AC-restore flaky → WoL).
    hp-01 = { ip = "192.168.2.54", install_disk = "/dev/sda" }
    # Laptop (i5-6200U Skylake: VT-x + AVX2) — 256GB Samsung MZ7LN256 SATA SSD (confirmed via
    # maintenance-mode `get disks`). THE KATA NODE (kata=true → metal_kata install image +
    # homelab.io/kata label; SLSA Phase-3 / agent-CI microVMs). Compute tier: tainted ephemeral.
    wk-metal-03 = { ip = "192.168.2.184", install_disk = "/dev/sda", kata = true }
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

  # Hostname is PINNED via the HostnameConfig document (highest-priority source, overrides DHCP),
  # so a cold-booted node no longer ghosts as `talos-xxx` if it DHCP-discovers before dnsmasq.
  # NOTE the provider quirk (terraform-provider-talos#296): the generated config already contains
  # a `HostnameConfig` doc with `auto: stable`. `auto` and `hostname` are mutually exclusive and
  # setting the legacy `machine.network.hostname` conflicts with it (`static hostname is already
  # set in v1alpha1 config`). The working fix is to patch that doc: set `hostname` AND delete the
  # `auto` key via the strategic-merge `$patch: delete` directive (per #296; field is `hostname`,
  # not `static`, confirmed against the v1.13 HostnameConfig reference).
  # ⚠️ INSTALL-TIME ONLY. Applying a hostname change to a *running* node re-derives the name live
  # and ghosts it (cluster-crashing — al9ef9 in #296, and seen here 2026-06-09). Changing this
  # field requires a reinstall: reset → maintenance → `tofu apply -replace` (a plain apply is a
  # no-op against an already-applied node). See docs/runbook.md.
  config_patches = concat(
    [yamlencode({
      machine = {
        install = {
          disk  = each.value.install_disk
          image = each.value.kata ? data.talos_image_factory_urls.metal_kata.urls.installer : local.talos_install_image
        }
      }
    })],
    # Kata-capable nodes advertise it; the `kata` RuntimeClass (kata.tf) schedules on this label.
    each.value.kata ? [yamlencode({
      machine = { nodeLabels = { "homelab.io/kata" = "true" } }
    })] : [],
    # AVX2 node label (boot-from-git, replaces the imperative `kubectl label`). The Haswell/Broadwell
    # ThinkPads have AVX2; hp-01 + thinkcentre do not. Talos applies machine.nodeLabels live.
    contains(local.avx2_nodes, each.key) ? [yamlencode({
      machine = { nodeLabels = { "homelab.io/cpu-avx2" = "true" } }
    })] : [],
    each.value.pin_hostname ? [yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = { "$patch" = "delete" }
    })] : [],
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

# wk-metal-03 — same ephemeral/compute tier. Applied after the node joins (step 7).
resource "kubernetes_node_taint" "laptop_kata" {
  metadata { name = "wk-metal-03" }
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
