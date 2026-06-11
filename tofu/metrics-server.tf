# Kubernetes Metrics Server (metrics.k8s.io). Talos ships none, so the cluster had no
# `kubectl top`, no HPA, and Longhorn couldn't read pod/node CPU+memory — which is why the
# Longhorn dashboard's "CPU & Memory" panels (longhorn_*_cpu/memory_*) were empty.
#
# --kubelet-insecure-tls: Talos kubelet serving certs are self-signed (not cluster-CA-signed)
# unless server-cert rotation is enabled, so metrics-server can't verify them — skip verification
# (LAN-internal; it scrapes the kubelet on each node's InternalIP:10250).
variable "metrics_server_version" {
  description = "metrics-server Helm chart version."
  type        = string
  default     = "3.12.2"
}

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = var.metrics_server_version

  values = [yamlencode({
    args = ["--kubelet-insecure-tls", "--kubelet-preferred-address-types=InternalIP"]
  })]
}
