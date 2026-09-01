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

# The node set + its per-node flags (install_disk / longhorn_disks / pin_hostname / kata) live in
# **machines/machines.yaml** — the one inventory, also read by machines/generate.py for the doc
# tables. `local.metal_nodes` (tofu/locals.tf) reduces it to the entries flagged
# `talos_metal_node: true`; the field semantics are documented there and in the YAML header.
# To add a node: add it to machines.yaml (docs/provisioning.md's onboarding recipe), regenerate
# the tables, apply. There is deliberately no `var.metal_nodes` override any more — a var that
# shadows the YAML would re-create the two-copies drift this indirection exists to remove.

data "talos_machine_configuration" "metal" {
  for_each = local.metal_nodes

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
    [local.registry_mirrors_patch],
    # Kata-capable nodes advertise it; the `kata` RuntimeClass (kata.tf) schedules on this label.
    each.value.kata ? [yamlencode({
      machine = { nodeLabels = { "homelab.io/kata" = "true" } }
    })] : [],
    # Kata nodes run k3d/kind-in-dind rides whose kata microVM grows to ~5Gi. Without a memory
    # reservation the kernel global-OOMs the node and takes cilium/longhorn as collateral
    # (FU-112b; incidents #63-66, #68, #69). Reserve memory + raise the HARD eviction threshold
    # so the kubelet EVICTS the (non-critical) ride ~½GiB before the kernel OOMs — cilium/longhorn
    # are system-node-critical and exempt from eviction. KATA NODES ONLY (they alone carry the k3d
    # spikes; desktops/VMs use different math and aren't urgent). Maps are written in FULL: Talos
    # kubelet.extraConfig can replace a nested map, so the cpu/pid/ephemeral + disk-pressure
    # defaults are restated here or they'd be lost (verify via .../proxy/configz after apply).
    each.value.kata ? [yamlencode({
      machine = {
        kubelet = {
          extraConfig = {
            systemReserved = {
              cpu                 = "50m"
              memory              = "512Mi"
              "ephemeral-storage" = "256Mi"
              pid                 = "100"
            }
            kubeReserved = {
              memory = "256Mi"
            }
            evictionHard = {
              "memory.available"   = "512Mi"
              "imagefs.available"  = "15%"
              "imagefs.inodesFree" = "5%"
              "nodefs.available"   = "10%"
              "nodefs.inodesFree"  = "5%"
            }
            # Image GC floor for the ride nodes (2026-09-01). On the two BULK-tier laptops
            # /var/lib/longhorn shares the Talos EPHEMERAL partition with the image store
            # (ADR-089 addendum), and the two floors never met: kubelet only starts GC at 85%
            # USED (default) while Longhorn refuses new replicas under 25% FREE — so every
            # per-build arc-runner/agent-base image accumulated (wk-metal-01: 21 arc-runner
            # builds = 75G of a 185G image store) until both bulk disks sat at ~23% free,
            # `Schedulable=False`, and no `longhorn-scratch` PVC — i.e. no docker:true worker
            # pod — could place fleet-wide (oracle-fleet#328/#329/#330, 2026-09-01). GC now
            # starts at 60% used and prunes unused images down to 50%, which keeps ≥25% free
            # while Longhorn's actual data stays under ~40% of the disk. Cost: re-pulls of old
            # image versions through the registry mirrors — nothing these nodes keep is unique.
            imageGCHighThresholdPercent = 60
            imageGCLowThresholdPercent  = 50
          }
        }
      }
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
    # Format + mount any extra disks under /var/lib/longhorn so longhorn-manager can see them
    # (it host-mounts only that path). Talos partitions (GPT, full disk) + makes a filesystem +
    # mounts. The mountpoint is the entry's `name`, which is ALSO its node.longhorn.io disk key —
    # never rename one that holds replicas, Longhorn would call the old key missing.
    # ⚠ Talos refuses a device that already carries a partition table; `talosctl wipe disk <dev>`
    # first. Prefer /dev/disk/by-id/wwn-* devices — this directive PARTITIONS, so a re-enumerated
    # /dev/sdX on a two-same-size-disk box formats the wrong one (hp-01, 2026-08-25).
    length(each.value.longhorn_disks) > 0 ? [yamlencode({
      machine = {
        disks = [for d in each.value.longhorn_disks : {
          device     = d.device
          partitions = [{ mountpoint = "/var/lib/longhorn/${d.name}" }]
        }]
      }
    })] : []
  )
}

# The compute/ephemeral tier (the laptops + the i5-3570K desktop) — not always-on, vanilla
# install (no Longhorn disk / iscsi). Taint them so stateful services (which tolerate nothing
# special) never schedule there; explicitly-tolerating workloads (e.g. CI runners) still can.
# Membership is the `ephemeral: true` flag in machines/machines.yaml (local.ephemeral_nodes) —
# it used to be four near-identical hand-written resources, one per node.
# Applied AFTER the node joins the cluster (docs/provisioning.md step 7).
resource "kubernetes_node_taint" "ephemeral" {
  for_each = local.ephemeral_nodes

  metadata { name = each.key }
  taint {
    key    = "homelab.io/ephemeral"
    value  = "true"
    effect = "NoSchedule"
  }
}

# State moves for the four resources the for_each above replaces (same node, same taint, same
# provider id) — so this refactor plans as a pure no-op instead of destroy+create, which would
# briefly untaint a live node and let stateful pods land on it.
moved {
  from = kubernetes_node_taint.laptop
  to   = kubernetes_node_taint.ephemeral["wk-metal-01"]
}

moved {
  from = kubernetes_node_taint.laptop_x250
  to   = kubernetes_node_taint.ephemeral["wk-metal-02"]
}

moved {
  from = kubernetes_node_taint.laptop_kata
  to   = kubernetes_node_taint.ephemeral["wk-metal-03"]
}

moved {
  from = kubernetes_node_taint.desktop_kata
  to   = kubernetes_node_taint.ephemeral["wk-metal-04"]
}

resource "talos_machine_configuration_apply" "metal" {
  for_each = local.metal_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.metal[each.key].machine_configuration
  node                        = each.value.ip
  endpoint                    = each.value.ip
}
