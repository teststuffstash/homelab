# Home Assistant on the cluster (Phase 2). Declarative via the kubernetes provider
# — explicit, reviewable manifests rather than an opaque chart.
#
# Storage: no dynamic provisioner yet, so a node-pinned hostPath PV under Talos's
# writable /var. HA is pinned to the same node. Single-instance (no HA-redundancy
# yet); data backs up to object storage later per ROADMAP. Longhorn/local-path is
# the future "real storage" step.
provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

locals {
  ha_node      = "wk-01" # node the PV + pod are pinned to
  ha_host_path = "/var/mnt/homeassistant"
  ha_nodeport  = 30123
}

resource "kubernetes_namespace" "ha" {
  metadata { name = "home-assistant" }
}

resource "kubernetes_persistent_volume" "ha" {
  metadata { name = "home-assistant-config" }
  spec {
    capacity                         = { storage = "10Gi" }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "manual"
    persistent_volume_source {
      host_path {
        path = local.ha_host_path
        type = "DirectoryOrCreate"
      }
    }
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [local.ha_node]
          }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "ha" {
  metadata {
    name      = "home-assistant-config"
    namespace = kubernetes_namespace.ha.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "manual"
    volume_name        = kubernetes_persistent_volume.ha.metadata[0].name
    resources { requests = { storage = "10Gi" } }
  }
}

resource "kubernetes_deployment" "ha" {
  metadata {
    name      = "home-assistant"
    namespace = kubernetes_namespace.ha.metadata[0].name
    labels    = { app = "home-assistant" }
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" } # RWO volume — never two pods at once
    selector { match_labels = { app = "home-assistant" } }
    template {
      metadata { labels = { app = "home-assistant" } }
      spec {
        node_selector = { "kubernetes.io/hostname" = local.ha_node }
        container {
          name  = "home-assistant"
          image = "ghcr.io/home-assistant/home-assistant:stable"
          env {
            name  = "TZ"
            value = "Europe/Tallinn"
          }
          port { container_port = 8123 }
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
          startup_probe { # HA's first boot is slow; allow up to 5 min
            http_get {
              path = "/"
              port = 8123
            }
            period_seconds    = 10
            failure_threshold = 30
          }
          liveness_probe {
            http_get {
              path = "/"
              port = 8123
            }
            period_seconds    = 30
            failure_threshold = 5
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.ha.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "ha" {
  metadata {
    name      = "home-assistant"
    namespace = kubernetes_namespace.ha.metadata[0].name
  }
  spec {
    type     = "NodePort"
    selector = { app = "home-assistant" }
    port {
      port        = 8123
      target_port = 8123
      node_port   = local.ha_nodeport
    }
  }
}

output "home_assistant_url" {
  # NOTE: use a node OTHER than the one running the pod (wk-01/.61). With Cilium
  # alongside kube-proxy, NodePort on the backend pod's own node drops traffic
  # (hairpin asymmetry); .51/.62 DNAT across fine. Real fix = Cilium LB (BGP) or
  # kubeProxyReplacement — see ROADMAP service-exposure.
  description = "Home Assistant UI (use cp-01/.51 — not the pod's node .61)."
  value       = "http://192.168.2.51:${local.ha_nodeport}"
}
