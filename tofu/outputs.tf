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
  description = "node => {ip, class, installer, schematic, version} — what each node's declaration says it should be running. Consumed by scripts/node-maintenance.sh upgrade."
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
        version   = local.talos_role_version[n.role]
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
      }
    },
  )
}
