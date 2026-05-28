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
}
