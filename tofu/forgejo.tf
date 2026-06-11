# Forgejo — self-hosted Git (Gitea-based). MINIMAL "kick the tires" deploy: built-in SQLite,
# in-memory sessions + cache, single replica, one small Longhorn PVC. No HA DB/cache — the chart
# dropped the bundled postgres/valkey subcharts, so minimal is the default (only `common` dep).
# Exposed on a BGP-advertised LoadBalancer VIP, HTTP only (no HAProxy/HTTPS name yet — add that
# when we invest more: github mirrors, Forgejo Actions runner, HTTPS). See ROADMAP "self-hosted git".
# Try it:  http://192.168.40.15:3000   (admin creds via `tofu output -raw forgejo_admin_password`)

variable "forgejo_version" {
  description = "Forgejo helm chart version (oci://code.forgejo.org/forgejo-helm/forgejo)."
  type        = string
  default     = "17.1.1"
}

locals {
  forgejo_lb_ip = "192.168.40.15" # BGP-advertised LoadBalancer VIP (.10-.14 taken)
}

resource "kubernetes_namespace" "forgejo" {
  metadata { name = "forgejo" }
}

resource "random_password" "forgejo_admin" {
  length  = 24
  special = false # Forgejo admin password: keep it shell/URL-safe for a throwaway trial
}

resource "helm_release" "forgejo" {
  name       = "forgejo"
  namespace  = kubernetes_namespace.forgejo.metadata[0].name
  repository = "oci://code.forgejo.org/forgejo-helm"
  chart      = "forgejo"
  version    = var.forgejo_version
  timeout    = 600

  values = [yamlencode({
    replicaCount = 1

    # Single RWO Longhorn volume for /data (sqlite db + repos). Survives pod restarts.
    persistence = {
      enabled      = true
      size         = "5Gi"
      storageClass = "longhorn"
    }

    # BGP LoadBalancer VIP (Cilium LB-IPAM via annotation; advertised by the bgp=advertise label).
    # SSH stays ClusterIP — HTTP clone is enough to try it out.
    service = {
      http = {
        type        = "LoadBalancer"
        port        = 3000
        labels      = { bgp = "advertise" }
        annotations = { "lbipam.cilium.io/ips" = local.forgejo_lb_ip }
      }
    }

    gitea = {
      admin = {
        username = "forgejo_admin"
        password = random_password.forgejo_admin.result
        email    = "admin@teststuff.net"
      }
      config = {
        database = { DB_TYPE = "sqlite3" }
        session  = { PROVIDER = "memory" }
        cache    = { ADAPTER = "memory" }
        # Reached via OPNsense HAProxy (TLS terminated there) at forgejo.teststuff.net; Forgejo
        # still serves plain HTTP on :3000 to the backend. ROOT_URL must be the public https name
        # so generated links + clone URLs are correct.
        server = {
          DOMAIN    = "forgejo.teststuff.net"
          ROOT_URL  = "https://forgejo.teststuff.net/"
          HTTP_PORT = "3000"
        }
      }
    }
  })]
}

output "forgejo_url" {
  value = "https://forgejo.teststuff.net  (direct: http://${local.forgejo_lb_ip}:3000; admin user: forgejo_admin)"
}

output "forgejo_admin_password" {
  value     = random_password.forgejo_admin.result
  sensitive = true
}
