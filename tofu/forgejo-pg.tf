# CNPG Postgres for Forgejo — replaces the minimal built-in SQLite, which 500'd under
# Forgejo Actions' write load (SQLite locking → per-second RunnerService/UpdateTask failures
# that took down the whole API). HA pair on Longhorn, same pattern as infisical-pg
# (argocd/resources/postgres/infisical-pg.yaml). The app role's password is tofu-seeded
# (basic-auth secret forgejo-pg-app) so Forgejo's helm DB config and CNPG agree without a
# generated secret. Git repos stay on Forgejo's own /data PVC (git is filesystem); only the
# relational metadata moves to Postgres.

resource "random_password" "forgejo_db" {
  length  = 32
  special = false # keep the app.ini connection string shell/URL-safe
}

resource "kubernetes_secret" "forgejo_pg_app" {
  metadata {
    name      = "forgejo-pg-app"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
  }
  type = "kubernetes.io/basic-auth" # CNPG initdb.secret expects basic-auth (username/password)
  data = {
    username = "forgejo"
    password = random_password.forgejo_db.result
  }
}

resource "kubernetes_manifest" "forgejo_pg" {
  manifest = {
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Cluster"
    metadata = {
      name      = "forgejo-pg"
      namespace = kubernetes_namespace.forgejo.metadata[0].name
    }
    spec = {
      instances = 2
      # Pin to the stable VM workers — the bare-metal nodes flap-reboot (qemu-guest-agent boot
      # hang, see metal-node-flapping); a flap on a node hosting a PG instance breaks the cluster.
      affinity = {
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [{
                key      = "kubernetes.io/hostname"
                operator = "In"
                values   = ["wk-01", "wk-02"]
              }]
            }]
          }
        }
      }
      storage = {
        size         = "5Gi"
        storageClass = "longhorn"
      }
      bootstrap = {
        initdb = {
          database = "forgejo"
          owner    = "forgejo"
          secret   = { name = kubernetes_secret.forgejo_pg_app.metadata[0].name }
        }
      }
    }
  }
}
