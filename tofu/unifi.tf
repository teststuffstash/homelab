# UniFi Network Application on the cluster — replaces the controller that ran in
# Docker on the (now-dead) Lenovo T61. Uses the same linuxserver image + an external
# MongoDB, exposed on a Cilium BGP LoadBalancer VIP so access points can be pointed
# at it with `set-inform http://192.168.40.12:8080/inform`.
#
# Why not the newer "UniFi OS Server" Helm chart: it needs privileged mode + host
# cgroups + systemd-as-PID1, which Talos (immutable) won't allow. The Network
# Application is a plain container, so it runs fine here.
#
# Storage: node-pinned hostPath (no dynamic provisioner yet), same pattern as
# homeassistant.tf. Requires the Talos kubelet extraMount /var/mnt/unifi (talos.tf) —
# applying that the first time triggers a rolling node reboot to establish the mount.
#
# Secrets: Mongo root + the unifi DB password are generated (random_password, kept in
# tofu state which is gitignored) — nothing sensitive in git.
#
# Boot-tested 2026-05-31 with an ephemeral emptyDir variant: image boots, connects to
# Mongo 7.0 (AVX OK via cpu=host), UI served on the BGP VIP, mixed TCP/UDP LB works.

locals {
  unifi_node   = "wk-02"             # node the pods + hostPath PVs are pinned to
  unifi_lb_ip  = "192.168.40.12"     # BGP-advertised LoadBalancer VIP (HA is .10)
  unifi_image  = "lscr.io/linuxserver/unifi-network-application:latest" # TODO: pin after first run
  mongo_image  = "mongo:7.0"         # UniFi 8.1+ supports mongo<=7.0; >4.4 needs AVX (cpu=host → ok)
  unifi_host   = "/var/mnt/unifi"
}

resource "random_password" "mongo_root" {
  length  = 24
  special = false
}

resource "random_password" "unifi_db" {
  length  = 24
  special = false
}

resource "kubernetes_namespace" "unifi" {
  metadata { name = "unifi" }
}

# Mongo root creds, the unifi app creds, and the init script that creates the unifi
# user/dbs on Mongo's first start — all in one Secret (keeps the password out of a
# plaintext ConfigMap).
resource "kubernetes_secret" "unifi_mongo" {
  metadata {
    name      = "unifi-mongo"
    namespace = kubernetes_namespace.unifi.metadata[0].name
  }
  data = {
    mongo-root-user = "root"
    mongo-root-pass = random_password.mongo_root.result
    mongo-user      = "unifi"
    mongo-pass      = random_password.unifi_db.result
    "init-mongo.js" = <<-EOT
      db.getSiblingDB("unifi").createUser({
        user: "unifi", pwd: "${random_password.unifi_db.result}",
        roles: [
          {role: "dbOwner", db: "unifi"},
          {role: "dbOwner", db: "unifi_stat"},
          {role: "dbOwner", db: "unifi_audit"},
          {role: "dbOwner", db: "unifi_restore"}
        ]
      });
    EOT
  }
}

# --- storage (node-pinned hostPath under the Talos /var/mnt/unifi mount) ---
resource "kubernetes_persistent_volume" "mongo" {
  metadata { name = "unifi-mongo" }
  spec {
    capacity                         = { storage = "5Gi" }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "manual"
    persistent_volume_source {
      host_path {
        path = "${local.unifi_host}/mongo"
        type = "DirectoryOrCreate"
      }
    }
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [local.unifi_node]
          }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume" "config" {
  metadata { name = "unifi-config" }
  spec {
    capacity                         = { storage = "5Gi" }
    access_modes                     = ["ReadWriteOnce"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = "manual"
    persistent_volume_source {
      host_path {
        path = "${local.unifi_host}/config"
        type = "DirectoryOrCreate"
      }
    }
    node_affinity {
      required {
        node_selector_term {
          match_expressions {
            key      = "kubernetes.io/hostname"
            operator = "In"
            values   = [local.unifi_node]
          }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim" "mongo" {
  metadata {
    name      = "unifi-mongo"
    namespace = kubernetes_namespace.unifi.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "manual"
    volume_name        = kubernetes_persistent_volume.mongo.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

resource "kubernetes_persistent_volume_claim" "config" {
  metadata {
    name      = "unifi-config"
    namespace = kubernetes_namespace.unifi.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "manual"
    volume_name        = kubernetes_persistent_volume.config.metadata[0].name
    resources { requests = { storage = "5Gi" } }
  }
}

# --- MongoDB ---
resource "kubernetes_deployment" "mongo" {
  metadata {
    name      = "unifi-mongo"
    namespace = kubernetes_namespace.unifi.metadata[0].name
    labels    = { app = "unifi-mongo" }
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = { app = "unifi-mongo" } }
    template {
      metadata { labels = { app = "unifi-mongo" } }
      spec {
        node_selector = { "kubernetes.io/hostname" = local.unifi_node }
        container {
          name  = "mongo"
          image = local.mongo_image
          args  = ["--bind_ip_all"]
          env {
            name = "MONGO_INITDB_ROOT_USERNAME"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.unifi_mongo.metadata[0].name
                key  = "mongo-root-user"
              }
            }
          }
          env {
            name = "MONGO_INITDB_ROOT_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.unifi_mongo.metadata[0].name
                key  = "mongo-root-pass"
              }
            }
          }
          port { container_port = 27017 }
          volume_mount {
            name       = "data"
            mount_path = "/data/db"
          }
          volume_mount {
            name       = "init"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }
          resources {
            requests = { cpu = "100m", memory = "256Mi" }
            limits   = { cpu = "1", memory = "1Gi" }
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.mongo.metadata[0].name
          }
        }
        volume {
          name = "init"
          secret {
            secret_name = kubernetes_secret.unifi_mongo.metadata[0].name
            items {
              key  = "init-mongo.js"
              path = "init-mongo.js"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "mongo" {
  metadata {
    name      = "unifi-mongo"
    namespace = kubernetes_namespace.unifi.metadata[0].name
  }
  spec {
    selector = { app = "unifi-mongo" }
    port {
      port        = 27017
      target_port = 27017
    }
  }
}

# --- UniFi Network Application ---
resource "kubernetes_deployment" "unifi" {
  metadata {
    name      = "unifi"
    namespace = kubernetes_namespace.unifi.metadata[0].name
    labels    = { app = "unifi" }
  }
  spec {
    replicas = 1
    strategy { type = "Recreate" } # RWO config volume — never two pods at once
    selector { match_labels = { app = "unifi" } }
    template {
      metadata { labels = { app = "unifi" } }
      spec {
        node_selector = { "kubernetes.io/hostname" = local.unifi_node }
        container {
          name  = "unifi"
          image = local.unifi_image
          env {
            name  = "PUID"
            value = "1000"
          }
          env {
            name  = "PGID"
            value = "1000"
          }
          env {
            name  = "TZ"
            value = "Europe/Tallinn"
          }
          env {
            name  = "MONGO_HOST"
            value = "${kubernetes_service.mongo.metadata[0].name}.${kubernetes_namespace.unifi.metadata[0].name}.svc.cluster.local"
          }
          env {
            name  = "MONGO_PORT"
            value = "27017"
          }
          env {
            name  = "MONGO_DBNAME"
            value = "unifi"
          }
          env {
            name  = "MONGO_AUTHSOURCE"
            value = "unifi"
          }
          env {
            name  = "MEM_LIMIT"
            value = "1024"
          }
          env {
            name = "MONGO_USER"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.unifi_mongo.metadata[0].name
                key  = "mongo-user"
              }
            }
          }
          env {
            name = "MONGO_PASS"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.unifi_mongo.metadata[0].name
                key  = "mongo-pass"
              }
            }
          }
          port { container_port = 8443 } # GUI
          port { container_port = 8080 } # device inform
          port {
            container_port = 3478
            protocol       = "UDP"
          } # STUN
          port {
            container_port = 10001
            protocol       = "UDP"
          } # AP discovery
          volume_mount {
            name       = "config"
            mount_path = "/config"
          }
          resources {
            requests = { cpu = "500m", memory = "1Gi" }
            limits   = { cpu = "2", memory = "2Gi" }
          }
          startup_probe { # UniFi's first boot (mongo init + Java) is slow
            http_get {
              path   = "/"
              port   = 8443
              scheme = "HTTPS"
            }
            period_seconds    = 10
            failure_threshold = 30
          }
          liveness_probe {
            http_get {
              path   = "/"
              port   = 8443
              scheme = "HTTPS"
            }
            period_seconds    = 30
            failure_threshold = 5
          }
        }
        volume {
          name = "config"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim.config.metadata[0].name
          }
        }
      }
    }
  }
}

# Single LoadBalancer holding all ports on one BGP VIP (mixed TCP/UDP — k8s >=1.26).
# L2 auto-discovery won't cross the BGP/L3 boundary, so adopt APs with set-inform
# pointed at this VIP:8080.
resource "kubernetes_service" "unifi" {
  metadata {
    name      = "unifi"
    namespace = kubernetes_namespace.unifi.metadata[0].name
    labels    = { bgp = "advertise" }
    annotations = {
      "lbipam.cilium.io/ips" = local.unifi_lb_ip
    }
  }
  spec {
    type     = "LoadBalancer"
    selector = { app = "unifi" }
    port {
      name        = "gui"
      port        = 8443
      target_port = 8443
      protocol    = "TCP"
    }
    port {
      name        = "inform"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
    port {
      name        = "stun"
      port        = 3478
      target_port = 3478
      protocol    = "UDP"
    }
    port {
      name        = "discovery"
      port        = 10001
      target_port = 10001
      protocol    = "UDP"
    }
  }
}

output "unifi_url" {
  description = "UniFi Network Application UI (BGP LoadBalancer VIP)."
  value       = "https://${local.unifi_lb_ip}:8443"
}
