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
    # kube-proxy disabled in Talos (cluster.proxy.disabled) → Cilium owns service
    # routing via eBPF. Uses Talos KubePrism on localhost:7445 for the API server.
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    k8sServicePort       = 7445
    # BGP control plane: advertise LoadBalancer service IPs to OPNsense (FRR).
    bgpControlPlane = { enabled = true }
    # Prometheus metrics: the agent exposes cilium_* incl. cilium_bgp_control_plane_* (BGP session
    # health — the alert that catches a peering drop before every .40.x VIP goes dark). The
    # serviceMonitors need the Prometheus Operator CRDs (kube-prometheus-stack) and are scraped via
    # the relaxed serviceMonitorSelector in monitoring.tf.
    prometheus = { enabled = true, serviceMonitor = { enabled = true } }
    # Hubble flow metrics (drop/dns/tcp/flow/icmp) — network-level observability ≈ continuous tests.
    # drop carries sourceContext=namespace (label `source`) so the POLICY_DENIED alert can scope to
    # agent namespaces (FU-020 enforcement: a netpol miss manifests as a worker HANG — the alert
    # names the cause). relay = the FU-020 harvest prereq: cluster-wide `hubble observe` for the
    # monitor-phase flow diff (without it flows are per-node + ring-buffered).
    hubble = {
      enabled = true
      metrics = {
        # drop: destination=FQDN when the DNS proxy knows the name (worker namespaces run L7 DNS
        # visibility via their CNPs), else IP — this is what turns "150 POLICY_DENIED from
        # oracle-fleet" into "150 × api.smith.langchain.com:443" without a live flow capture.
        # dns: query names per source namespace — what a namespace is TRYING to resolve.
        # Cardinality: bounded at homelab scale (denied destinations + unique lookups).
        enabled = [
          "dns:query;sourceContext=namespace",
          "drop:sourceContext=namespace;destinationContext=dns|ip",
          "tcp", "flow", "icmp", "port-distribution",
        ]
        serviceMonitor = { enabled = true }
      }
      relay = { enabled = true }
    }
    # single operator is plenty for a homelab; default 2 (High Availability, anti-affinity) just
    # leaves a second replica stuck when a node hasn't cached the image yet.
    operator = { replicas = 1, prometheus = { enabled = true, serviceMonitor = { enabled = true } } }
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
