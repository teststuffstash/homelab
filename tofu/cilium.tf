# Cilium CNI as a Helm release (Talos runs with cni=none). This makes the CNI
# part of "boot from git" — recreating the cluster restores Cilium automatically.
# Provider is configured from the Talos-issued kubeconfig (known after the cluster
# is bootstrapped).
provider "helm" {
  kubernetes {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}

resource "helm_release" "cilium" {
  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io"
  chart      = "cilium"
  version    = var.cilium_version

  # Talos-specific: locked-down host needs explicit capabilities + a pre-mounted
  # cgroup (Talos mounts cgroup2 at /sys/fs/cgroup, so Cilium must not auto-mount).
  # kube-proxy is left in place (no kubeProxyReplacement) for now.
  values = [yamlencode({
    ipam = { mode = "kubernetes" }
    # single operator is plenty for a homelab; default 2 (HA, anti-affinity) just
    # leaves a second replica stuck when a node hasn't cached the image yet.
    operator = { replicas = 1 }
    cgroup = {
      autoMount = { enabled = false }
      hostRoot  = "/sys/fs/cgroup"
    }
    securityContext = {
      capabilities = {
        ciliumAgent      = ["CHOWN", "KILL", "NET_ADMIN", "NET_RAW", "IPC_LOCK", "SYS_ADMIN", "SYS_RESOURCE", "DAC_OVERRIDE", "FOWNER", "SETGID", "SETUID"]
        cleanCiliumState = ["NET_ADMIN", "SYS_ADMIN", "SYS_RESOURCE"]
      }
    }
  })]

  depends_on = [talos_machine_bootstrap.this]
}
