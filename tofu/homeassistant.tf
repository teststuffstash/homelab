# Home Assistant on the cluster (Phase 2). Declarative via the kubernetes provider
# — explicit, reviewable manifests rather than an opaque chart.
#
# Storage: Longhorn (replicated, default StorageClass) — dynamically provisioned, so the
# pod is NOT node-pinned and reschedules freely across the iscsi-capable nodes. Data
# backs up to object storage later (FU-013).
provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

locals {
  ha_lb_ip = "192.168.40.10" # stable BGP-advertised LoadBalancer VIP
}

resource "kubernetes_namespace" "ha" {
  metadata { name = "home-assistant" }
}

resource "kubernetes_persistent_volume_claim" "ha" {
  metadata {
    name      = "home-assistant-config"
    namespace = kubernetes_namespace.ha.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn"
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
          startup_probe { # Home Assistant's first boot is slow; allow up to 5 min
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

  lifecycle {
    # A manual `kubectl rollout restart` stamps spec.template.metadata.annotations
    # (kubectl.kubernetes.io/restartedAt). We don't manage pod-template annotations here, so ignore
    # them rather than reverting the stamp on every plan (this was the perpetual "HA drift").
    ignore_changes = [spec[0].template[0].metadata[0].annotations]
  }
}

resource "kubernetes_service" "ha" {
  metadata {
    name      = "home-assistant"
    namespace = kubernetes_namespace.ha.metadata[0].name
    labels    = { bgp = "advertise" } # opt in to BGP advertisement (CiliumBGPAdvertisement selector)
    annotations = {
      "lbipam.cilium.io/ips" = local.ha_lb_ip # pin a stable VIP from the pool
    }
  }
  spec {
    type     = "LoadBalancer"
    selector = { app = "home-assistant" }
    port {
      port        = 8123
      target_port = 8123
    }
  }
}

output "home_assistant_url" {
  description = "Home Assistant UI (BGP LoadBalancer VIP, reachable from the whole LAN)."
  value       = "http://${local.ha_lb_ip}:8123"
}
