# Kata Containers RuntimeClass — the microVM-per-pod primitive (docs/slsa.md Phase-3
# convergence note: one primitive, three consumers — agent k3d/kind CI gates now, the Tekton
# build plane at SLSA Phase 3, Confidential Containers at Phase 4).
#
# A `runtimeClassName: kata` pod runs inside a lightweight KVM VM: rootful podman/docker,
# k3d/kind and testcontainers work exactly as on a laptop, and `privileged: true` inside it is
# root in the microVM — NOT on the node — so the agent sandbox (FU-020 egress, ADR-087 brokered
# creds) survives; Cilium policies still apply at the pod's veth.
#
# The handler exists only on nodes installed with the metal_kata image (metal.tf `kata = true`,
# BIOS VT-x required); the scheduling block confines kata pods to those nodes and lets them
# tolerate the compute-tier taint. Overhead reserves headroom for the VM itself (~8G laptops ⇒
# roughly one ~4G microVM at a time — matches the WIP=1 agent model).
# (kubernetes_manifest, not kubernetes_runtime_class_v1 — the typed resource has no
# scheduling/overhead support.)
resource "kubernetes_manifest" "runtime_class_kata" {
  manifest = {
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata   = { name = "kata" }
    handler    = "kata"
    scheduling = {
      nodeSelector = { "homelab.io/kata" = "true" }
      tolerations = [{
        key      = "homelab.io/ephemeral"
        operator = "Equal"
        value    = "true"
        effect   = "NoSchedule"
      }]
    }
    overhead = {
      podFixed = {
        memory = "512Mi"
        cpu    = "250m"
      }
    }
  }
}
