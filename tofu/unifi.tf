# UniFi Network Application on the cluster — replaces the controller that ran in
# Docker on the (now-dead) Lenovo T61. Uses the same linuxserver image + an external
# MongoDB, exposed on a Cilium BGP LoadBalancer VIP so access points can be pointed
# at it with `set-inform http://192.168.40.12:8080/inform`.
#
# Why not the newer "UniFi OS Server" Helm chart: it needs privileged mode + host
# cgroups + systemd-as-PID1, which Talos (immutable) won't allow. The Network
# Application is a plain container, so it runs fine here.
#
# Storage: Longhorn (replicated, default StorageClass) for both the Mongo data and the
# UniFi config — dynamically provisioned, so neither pod is node-pinned.
#
# Secrets: Mongo root + the unifi DB password are generated (random_password, kept in
# tofu state which is gitignored) — nothing sensitive in git.

locals {
  unifi_lb_ip = "192.168.40.12"     # BGP-advertised LoadBalancer VIP (HA is .10)
  # Pinned to the digest running after the controller migration (UniFi Network 10.3.58,
  # 2026-06-04). Pinned by digest so a registry-side :latest move can't desync the app from
  # the Mongo schema on a pod reschedule. To upgrade: bump to a newer linuxserver digest
  # deliberately, then `tofu apply` (Recreate strategy → brief downtime, slow first boot).
  unifi_image = "lscr.io/linuxserver/unifi-network-application@sha256:f87c4d57285f3118a0bad24f696f5aa088859d332b5bf865cdb8e515a1c819ab"
  mongo_image = "mongo:7.0"         # UniFi 8.1+ supports mongo<=7.0; >4.4 needs AVX (cpu=host → ok)
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

# --- storage (Longhorn, dynamically provisioned, replicated) ---
resource "kubernetes_persistent_volume_claim" "mongo" {
  metadata {
    name      = "unifi-mongo"
    namespace = kubernetes_namespace.unifi.metadata[0].name
  }
  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "longhorn"
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
    storage_class_name = "longhorn"
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
