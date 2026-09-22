# Both are secrets — they're written to state (keep state out of git) and can be
# dumped to files for talosctl/kubectl. Do NOT commit the rendered files.
output "talosconfig" {
  description = "talosctl client config. Save: tofu output -raw talosconfig > talosconfig"
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

output "kubeconfig" {
  description = "kubeconfig. Save: tofu output -raw kubeconfig > kubeconfig"
  value       = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = local.cluster_endpoint
}

# Per-node install target — the DECLARED half of the upgrade verb and of FU-235's
# declared-vs-live diff. The rule ADR-014's 2026-09-18 amendment makes explicit: an upgrade's
# `--image` must match on THREE axes (platform, schematic, version), so it is computed here from
# the declaration rather than typed at the terminal. `talosctl get extensions` reports the live
# schematic id, which is what `schematic` below is compared against after an upgrade.
#   devbox run mgmt-tf output -json node_install_targets
output "node_install_targets" {
  description = "node => {ip, class, installer, schematic, version, role, install_disk, ephemeral} — what each node's declaration says it should be running. Consumed by scripts/node-maintenance.sh upgrade and by the management sentinel's install-impact line."
  value = merge(
    # VMs (talos.tf + proxmox.tf/nx02.tf): the `longhorn` flag picks the schematic, the ROLE picks
    # the version (image.tf). The nocloud PLATFORM is the half ADR-014 is about — a generic
    # ghcr.io/siderolabs/installer here reinstalls the node as `metal` and ghosts it.
    {
      for k, n in var.nodes : k => {
        ip        = local.node_ip[k]
        class     = "vm"
        installer = data.talos_image_factory_urls.vm[local.vm_image_key[k]].urls.installer
        schematic = n.longhorn ? talos_image_factory_schematic.longhorn.id : talos_image_factory_schematic.this.id
        version   = local.node_talos_version[k]
        # The INSTALL-TIME half (ADR-132 §MB4 layer 2): fields Talos honours only on the next
        # install, so `plan` shows them as a clean in-place config apply. The sentinel diffs this
        # output's before/after per node and names the node + field on the PR — never the value.
        role         = n.role
        install_disk = local.vm_install_disk
        ephemeral    = { max_size = null, disk_selector = null }
      }
    },
    # Metal (metal.tf): `kata: true` in machines/machines.yaml selects the metal_kata schematic —
    # pass the wrong one and the upgrade silently drops the node back to plain metal.
    {
      for k, m in local.metal_nodes : k => {
        ip        = m.ip
        class     = "metal"
        installer = m.kata ? data.talos_image_factory_urls.metal_kata.urls.installer : local.talos_install_image
        schematic = m.kata ? talos_image_factory_schematic.metal_kata.id : talos_image_factory_schematic.metal.id
        version   = var.talos_version_worker
        # install-time (see the VM half): machine_type, install.disk, the EPHEMERAL VolumeConfig
        role         = m.controlplane ? "controlplane" : "worker"
        install_disk = m.install_disk
        ephemeral    = { max_size = m.ephemeral_max_size, disk_selector = m.ephemeral_disk_selector }
      }
    },
  )
}

# Per-node DECLARED Kubernetes-facing state — the labels/taints/EPHEMERAL axes of FU-235's
# declared-vs-live diff (scripts/mgmt-probe.sh check_nodes, docs/management-box.md §MB2). These
# are the fields tofu cannot see drift on: Talos `machine.nodeLabels` ride the machine config
# (state records DELIVERY, never the Node object), the ephemeral taint's resource cannot own an
# atomic list another manager rewrote (metal.tf), and the EPHEMERAL VolumeConfig is honoured only
# at install. Each expression below restates the CONDITION the patch/resource it mirrors uses —
# edit both together (the source is named on each line). The EPHEMERAL diskSelector is NOT here:
# node_install_targets carries it (`.ephemeral`, the install-time half) and the probe reads it there.
#   labels          only the keys tofu itself declares; the probe compares over the UNION of
#                   keys across nodes, so a declared key missing live AND an undeclared one present
#                   live (an imperative `kubectl label`) both read as drift
#   taints          "key=value:effect", same union semantics
output "node_declared_k8s" {
  description = "node => {labels, taints} — the declared half of the belt's registered/labels/taints axes (scripts/mgmt-probe.sh check_nodes)."
  value = merge(
    {
      for k, n in var.nodes : k => {
        labels = merge(
          contains(local.avx2_nodes, k) ? { "homelab.io/cpu-avx2" = "true" } : {},                       # talos.tf patch
          contains(local.ephemeral_nodes, k) ? { "homelab.io/ephemeral" = "true" } : {},                 # talos.tf patch
          can(local.machine_zones[k]) ? { "topology.kubernetes.io/zone" = local.machine_zones[k] } : {}, # longhorn.tf
        )
        taints = concat(
          contains(local.ephemeral_nodes, k) ? ["homelab.io/ephemeral=true:NoSchedule"] : [],    # metal.tf taint
          n.role == "controlplane" ? ["node-role.kubernetes.io/control-plane=:NoSchedule"] : [], # Talos default
        )
      }
    },
    {
      for k, m in local.metal_nodes : k => {
        labels = merge(
          m.kata ? { "homelab.io/kata" = "true" } : {},                                                  # metal.tf patch
          m.arc ? { "homelab.io/ephemeral" = "true" } : {},                                              # metal.tf patch
          contains(local.avx2_nodes, k) ? { "homelab.io/cpu-avx2" = "true" } : {},                       # metal.tf patch
          can(local.machine_zones[k]) ? { "topology.kubernetes.io/zone" = local.machine_zones[k] } : {}, # longhorn.tf
        )
        taints = concat(
          contains(local.ephemeral_nodes, k) ? ["homelab.io/ephemeral=true:NoSchedule"] : [], # metal.tf taint
          m.controlplane ? ["node-role.kubernetes.io/control-plane=:NoSchedule"] : [],        # Talos default
        )
      }
    },
  )
}
