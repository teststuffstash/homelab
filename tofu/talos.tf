# Provider-agnostic cluster definition. Nothing here knows about Proxmox — in a
# DR rebuild this file is reused unchanged; only proxmox.tf/providers.tf change.

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

data "talos_machine_configuration" "node" {
  for_each = var.nodes

  cluster_name       = var.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = each.value.role
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = trimprefix(var.kubernetes_version, "v")
  talos_version      = var.talos_version

  config_patches = [
    yamlencode({
      machine = {
        # hostname comes from the Proxmox nocloud datasource (the VM name);
        # setting it here too makes Talos reject the config as a conflict.
        install = { disk = "/dev/sda" }
      }
    }),
  ]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.controlplane_ips
  nodes                = sort(values(local.node_ip))
}

resource "talos_machine_configuration_apply" "node" {
  for_each = var.nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.node[each.key].machine_configuration
  node                        = local.node_ip[each.key]
  endpoint                    = local.node_ip[each.key]

  depends_on = [proxmox_virtual_environment_vm.node]
}

resource "talos_machine_bootstrap" "this" {
  node                 = local.first_cp_ip
  endpoint             = local.first_cp_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.node]
}

resource "talos_cluster_kubeconfig" "this" {
  node                 = local.first_cp_ip
  endpoint             = local.first_cp_ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}
