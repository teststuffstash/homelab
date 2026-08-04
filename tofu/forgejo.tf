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

# Forgejo admin credentials as a Secret the chart REFERENCES (FU-136) — the preparatory half of the
# ArgoCD lever, same reason as monitoring.tf's grafana-admin: the release cannot move to a PUBLIC
# repo while its values carry a live password. Key names are the chart's (`username`/`password`,
# templates/gitea/admin-secret.yaml); the admin EMAIL stays a plain value, it is not a secret.
# NAME is `forgejo-admin-creds`, NOT `forgejo-admin`: the chart's own generated secret already owns
# that name (`{{ gitea.fullname }}-admin`), and the first apply refused with "already exists" rather
# than taking it over. Handing the chart back a name it manages itself would race Helm's delete of
# the old one against tofu's create of the new.
# The DB password needs no new Secret — `forgejo-pg-app` (forgejo-pg.tf) already holds exactly it,
# and the chart's `additionalConfigFromEnvs` injects it into the init-app-ini container, which is
# where config_environment.sh turns FORGEJO__<SECTION>__<KEY> into app.ini.
resource "kubernetes_secret" "forgejo_admin" {
  metadata {
    name      = "forgejo-admin-creds"
    namespace = kubernetes_namespace.forgejo.metadata[0].name
  }
  data = {
    username = "forgejo_admin"
    password = random_password.forgejo_admin.result
  }
  type = "Opaque"
}

# forgejo MOVED to ArgoCD on 2026-08-04 (FU-136, the ArgoCD lever): argocd/platform/forgejo.yaml.
# What stays here is what tofu still owns: the namespace, the admin password (random_password +
# the forgejo-admin-creds Secret the chart references) and the outputs below. The chart's OCI
# registration for ArgoCD is kubernetes_secret.argocd_repo_forgejo_oci in argocd.tf.

output "forgejo_url" {
  value = "https://forgejo.teststuff.net  (direct: http://${local.forgejo_lb_ip}:3000; admin user: forgejo_admin)"
}

output "forgejo_admin_password" {
  value     = random_password.forgejo_admin.result
  sensitive = true
}
