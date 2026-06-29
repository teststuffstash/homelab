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

  # Nodes whose CPU has AVX2 — set as a Talos machine.nodeLabels (homelab.io/cpu-avx2=true) so the
  # label travels with the node's machine config and survives a reinstall (boot-from-git), instead of
  # an imperative `kubectl label`. Used to schedule AVX2-only workloads (opencode's Bun runtime SIGILLs
  # without it; see agents/agent-session.sh). Verified via /proc/cpuinfo: the Xeon E5-2680v4 VMs and the
  # Haswell/Broadwell ThinkPads have AVX2; hp-01 + thinkcentre (Pentium G840) do NOT. Keyed by node name,
  # spanning both var.nodes (VMs) and var.metal_nodes — membership-checked in talos.tf/metal.tf patches.
  avx2_nodes = toset(["wk-01", "wk-02", "wk-metal-01", "wk-metal-02"])
}
