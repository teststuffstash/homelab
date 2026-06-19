# Forgejo — self-hosted Git (Gitea-based). DB is **CNPG Postgres** (tofu/forgejo-pg.tf) — the
# built-in SQLite 500'd under Forgejo Actions' write load. In-memory sessions + cache, single
# replica, one small Longhorn PVC for /data (git repos + attachments; relational data is in PG).
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

  # PG cluster + its -rw service and the app secret must exist before Forgejo starts.
  depends_on = [kubernetes_manifest.forgejo_pg, kubernetes_secret.forgejo_pg_app]

  values = [yamlencode({
    replicaCount = 1

    # Single RWO Longhorn volume for /data (git repos + attachments). Survives pod restarts.
    persistence = {
      enabled      = true
      size         = "5Gi"
      storageClass = "longhorn"
    }

    # BGP LoadBalancer VIP (Cilium LB-IPAM via annotation; advertised by the bgp=advertise label).
    # http + ssh share one VIP (.40.15) via a Cilium LB-IPAM sharing-key (distinct ports 3000/22).
    # SSH is reached from the LAN via an OPNsense HAProxy TCP frontend on forgejo.teststuff.net:22.
    service = {
      http = {
        type   = "LoadBalancer"
        port   = 3000
        labels = { bgp = "advertise" }
        annotations = {
          "lbipam.cilium.io/ips"         = local.forgejo_lb_ip
          "lbipam.cilium.io/sharing-key" = "forgejo"
        }
      }
      ssh = {
        type   = "LoadBalancer"
        port   = 22
        labels = { bgp = "advertise" }
        annotations = {
          "lbipam.cilium.io/ips"         = local.forgejo_lb_ip
          "lbipam.cilium.io/sharing-key" = "forgejo"
        }
      }
    }

    gitea = {
      admin = {
        username = "forgejo_admin"
        password = random_password.forgejo_admin.result
        email    = "admin@teststuff.net"
      }
      config = {
        # CNPG Postgres (tofu/forgejo-pg.tf). PASSWD is the tofu-seeded forgejo-pg-app password,
        # so this connection string and the DB role always match. HOST = the CNPG -rw service.
        database = {
          DB_TYPE = "postgres"
          HOST    = "forgejo-pg-rw.forgejo.svc.cluster.local:5432"
          NAME    = "forgejo"
          USER    = "forgejo"
          PASSWD  = random_password.forgejo_db.result
        }
        session = { PROVIDER = "memory" }
        cache    = { ADAPTER = "memory" }
        # Private instance: close LAN self-signup. Admins still create users (we make `rasmus`).
        service = { DISABLE_REGISTRATION = true }
        # Forgejo Actions (self-hosted CI — SLSA Build L2, see docs/slsa.md). The act_runner
        # is tofu/forgejo-runner.tf. DEFAULT_ACTIONS_URL=github so `uses: actions/*` resolve.
        actions = { ENABLED = "true", DEFAULT_ACTIONS_URL = "github" }
        # Reached via OPNsense HAProxy (TLS terminated there) at forgejo.teststuff.net; Forgejo
        # still serves plain HTTP on :3000 to the backend. ROOT_URL must be the public https name
        # so generated links + clone URLs are correct.
        server = {
          DOMAIN     = "forgejo.teststuff.net"
          ROOT_URL   = "https://forgejo.teststuff.net/"
          HTTP_PORT  = "3000"
          SSH_DOMAIN = "forgejo.teststuff.net" # clone URLs: git@forgejo.teststuff.net:org/repo.git
          SSH_PORT   = "22"                     # advertised port (HAProxy .2.9:22 -> .40.15:22)
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
