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
      # FU-082: a BestEffort DB is first to be OOM-killed under pressure. Requests → Burstable +
      # honest scheduling (~110Mi steady); the memory limit is generous headroom, not a tight cap.
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { memory = "768Mi" }
      }
      # Expose CNPG metrics — the operator creates a PodMonitor that kube-prometheus-stack
      # auto-discovers (open selectors). Feeds the cnpg alerts + dashboard (monitoring.tf).
      monitoring = { enablePodMonitor = true }
      # One instance per PHYSICAL box (topology.kubernetes.io/zone = the chassis; the pve VMs all
      # read `proxmox`). The old hostname pin to wk-01/wk-02 (from the metal-flapping era) put
      # both instances on one hypervisor — found at the 2026-09-21 pve GPU-swap drain.
      # Zone list = the untainted boxes with a std Longhorn disk: the volume is strict-local
      # replica-1, so an instance only runs where its disk is (ADR-114, tofu/longhorn.tf).
      affinity = {
        podAntiAffinityType = "required"
        topologyKey         = "topology.kubernetes.io/zone"
        nodeAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
              matchExpressions = [{
                key      = "topology.kubernetes.io/zone"
                operator = "In"
                values   = ["hp-01", "m70s"]
              }]
            }]
          }
        }
      }
      # Promote the updated replica instead of restarting the primary in place on a spec change.
      primaryUpdateMethod = "switchover"
      storage = {
        size         = "5Gi"
        storageClass = kubernetes_storage_class.longhorn_local_std.metadata[0].name
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
