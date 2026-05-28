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
