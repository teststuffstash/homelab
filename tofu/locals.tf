locals {
  controlplane = { for k, n in var.nodes : k => n if n.role == "controlplane" }
  workers      = { for k, n in var.nodes : k => n if n.role == "worker" }

  # IP (without CIDR mask) per node.
  node_ip = { for k, n in var.nodes : k => split("/", n.ip_cidr)[0] }

  # Deterministic pick of the bootstrap control-plane (lowest key).
  first_cp_key = sort(keys(local.controlplane))[0]
  first_cp_ip  = local.node_ip[local.first_cp_key]

  cluster_endpoint = "https://${local.first_cp_ip}:6443"

  controlplane_ips = sort([for k, n in local.controlplane : local.node_ip[k]])

  # ---- machines/machines.yaml: the ONE inventory -----------------------------------------------
  # The repo-root inventory is the single source of truth for what boxes exist and how the metal
  # workers install; everything below is DERIVED from it, so a flag is edited in exactly one place
  # (machines/machines.yaml) and both tofu and the doc generator (machines/generate.py) follow.
  # Reading a file at plan time is pure data — no provider, no state, no ordering dependency.
  machines = yamldecode(file("${path.module}/../machines/machines.yaml")).machines

  # Bare-metal Talos workers (metal.tf). Booleans are compared to `true` (not just try()-defaulted)
  # so an explicit `kata: null` in YAML degrades to false instead of erroring in a conditional.
  metal_nodes = {
    for m in local.machines : m.name => {
      ip           = m.ip                               # DHCP-reserved IP (maintenance-mode + ongoing node address)
      install_disk = m.install_disk                     # target disk for the install (NOT the optane cache)
      optane_disks = tolist(try(m.optane_disks, []))    # extra disks → Longhorn "fast" tier
      pin_hostname = try(m.pin_hostname, true) != false # HostnameConfig patch; default true
      kata         = try(m.kata, false) == true         # metal_kata install image + homelab.io/kata label
    } if try(m.talos_metal_node, false) == true
  }

  # Nodes whose CPU has AVX2 — set as a Talos machine.nodeLabels (homelab.io/cpu-avx2=true) so the
  # label travels with the node's machine config and survives a reinstall (boot-from-git), instead of
  # an imperative `kubectl label`. Used to schedule AVX2-only workloads (opencode's Bun runtime SIGILLs
  # without it; see agents/agent-session.sh). Verified via /proc/cpuinfo: the Xeon E5-2680v4 VMs and the
  # Haswell/Broadwell ThinkPads have AVX2; hp-01 + thinkcentre (Pentium G840) do NOT. Keyed by node name,
  # spanning both VMs and metal — membership-checked in talos.tf/metal.tf patches.
  avx2_nodes = toset([for m in local.machines : m.name if try(m.avx2, false) == true])

  # Compute/ephemeral-tier nodes — the homelab.io/ephemeral NoSchedule taint in metal.tf.
  ephemeral_nodes = toset([for m in local.machines : m.name if try(m.ephemeral, false) == true])
}
