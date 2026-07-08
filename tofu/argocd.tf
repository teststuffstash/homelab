# ArgoCD — the GitOps seam (ADR forthcoming; see docs/secrets.md + argocd/README.md).
#
# This file is the *entire* imperative footprint of the GitOps layer. Everything it
# does is one of three bootstrap jobs that ArgoCD cannot do for itself because they
# are UPSTREAM of ArgoCD's own ability to run:
#
#   1. Install ArgoCD (the controller) + expose its UI on a BGP VIP.
#   2. Seed the ONE secret set ESO can't bootstrap itself — Infisical's encryption/auth
#      keys + its Postgres credentials — from the KeePass wallet (scripts/keepass-env.sh).
#   3. Give ArgoCD a read credential to the (private) git repo, and point it at GitHub.
#
# After this applies, the app-of-apps takes over: ArgoCD reconciles argocd/platform/
# (CNPG → Postgres → Infisical → ESO) from git, and every downstream secret flows
# Infisical → ESO → namespace Secret. We bootstrap against GitHub on purpose (public-
# readable later, no Forgejo dependency yet) and cut the repoURL over to Forgejo once
# that path is real — FU-007, see argocd/README.md "Forgejo cutover".

locals {
  argocd_lb_ip    = "192.168.40.17" # BGP-advertised VIP (.16 = garage; .17/.18 free)
  infisical_lb_ip = "192.168.40.18"

  # Infisical talks to its CNPG cluster over the in-cluster -rw service. sslmode=disable:
  # the node-pg client rejects CNPG's self-signed server cert with sslmode=require
  # (SELF_SIGNED_CERT_IN_CHAIN), and CNPG permits non-TLS host connections. Traffic is
  # pod-to-pod on the cluster network; revisit if Cilium transparent-encryption matters.
  infisical_db_uri = "postgresql://infisical:${var.infisical_db_password}@infisical-pg-rw.infisical.svc.cluster.local:5432/infisical?sslmode=disable"
}

# ---------------------------------------------------------------------------
# 1 · ArgoCD controller
# ---------------------------------------------------------------------------
resource "helm_release" "argocd" {
  name             = "argocd"
  namespace        = "argocd"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  timeout          = 900

  values = [yamlencode({
    global = { domain = "argocd.teststuff.net" }

    configs = {
      params = {
        # TLS is terminated at the OPNsense HAProxy edge (auto-renewed ACME cert);
        # argocd-server serves plain HTTP on the backend. Avoids the gRPC/HTTP TLS
        # double-termination dance and matches grafana/forgejo.
        "server.insecure" = true
      }
      cm = {
        # The ESO admission webhook defaults a pile of spec fields (remoteRef.*Strategy/Policy,
        # target.creation/deletionPolicy) that aren't in git, so EVERY ExternalSecret reads
        # OutOfSync (though Healthy). Ignore those defaulted paths globally — clears the drift
        # across all ESO-delivering apps (crossplane-providers, sleep, openrouter-operator, …).
        "resource.customizations.ignoreDifferences.external-secrets.io_ExternalSecret" = yamlencode({
          jqPathExpressions = [
            ".spec.target.creationPolicy",
            ".spec.target.deletionPolicy",
            ".spec.data[]?.remoteRef.conversionStrategy",
            ".spec.data[]?.remoteRef.decodingStrategy",
            ".spec.data[]?.remoteRef.metadataPolicy",
            ".spec.data[]?.remoteRef.nullBytePolicy",
          ]
        })
        # App-of-apps children: `spec.source.directory.recurse: false` is the default, which ArgoCD
        # drops from the desired state but the live Application keeps → every child Application reads
        # OutOfSync (so `platform`/`sleep` do too). Ignore that one defaulted field.
        "resource.customizations.ignoreDifferences.argoproj.io_Application" = yamlencode({
          jqPathExpressions = [".spec.source.directory"]
        })
      }
    }

    # The UI/API Service stays ClusterIP; the BGP VIP is a separate labelled Service
    # below (the chart's service template can't carry the bgp=advertise label, same as
    # garage.tf). Redis/repo-server/controller keep their defaults.
    server = { service = { type = "ClusterIP" } }
  })]
}

# LAN-reachable VIP for the ArgoCD UI (Cilium BGP via the bgp=advertise label + LB-IPAM
# annotation). HTTP only — HAProxy terminates TLS at argocd.teststuff.net.
resource "kubernetes_service" "argocd_lb" {
  metadata {
    name        = "argocd-server-lb"
    namespace   = "argocd"
    labels      = { bgp = "advertise" }
    annotations = { "lbipam.cilium.io/ips" = local.argocd_lb_ip }
  }
  spec {
    type = "LoadBalancer"
    selector = {
      "app.kubernetes.io/name"     = "argocd-server"
      "app.kubernetes.io/instance" = "argocd"
    }
    port {
      name        = "http"
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
  }
  depends_on = [helm_release.argocd]
}

# Repo credential: the homelab repo is private, so ArgoCD needs a read token to pull it
# from GitHub. The PAT comes from KeePass (TF_VAR_argocd_github_pat). This is the only
# git credential ArgoCD needs during bootstrap; post-Forgejo-cutover it's delivered via
# ESO instead.
resource "kubernetes_secret" "argocd_repo_github" {
  metadata {
    name      = "repo-homelab-github"
    namespace = "argocd"
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }
  data = {
    type     = "git"
    url      = var.argocd_repo_url
    username = "git" # fine-grained PAT: username is ignored, token is the password
    password = var.argocd_github_pat
  }
  depends_on = [helm_release.argocd]
}

# Read credential for app repos ArgoCD reconciles (per ADR-004 per-app-repo). Same PAT
# (org-scoped). Add more entries as apps onboard, or switch to an org creds-template.
resource "kubernetes_secret" "argocd_repo_snore_recorder" {
  metadata {
    name      = "repo-snore-recorder-github"
    namespace = "argocd"
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }
  data = {
    type     = "git"
    url      = "https://github.com/teststuffstash/snore-recorder.git"
    username = "git"
    password = var.argocd_github_pat
  }
  depends_on = [helm_release.argocd]
}

# (Removed: repo-sleep-tracking-github credential. FU-025 extracted the sleep stack into the PUBLIC
# sleep-iac repo, so ArgoCD no longer reads the private sleep-tracking.git — the child apps source
# sleep-iac anonymously. The credential is unused; deleted here + from the argocd/README secret table.)

# Read credential for oracle-iac — unlike sleep-iac it is PRIVATE (permanently), so the root
# `oracle` app + its children can't read it anonymously. Same org PAT as the other credentials;
# if the PAT is fine-grained/repo-scoped, oracle-iac must be added to its repository list.
resource "kubernetes_secret" "argocd_repo_oracle_iac" {
  metadata {
    name      = "repo-oracle-iac-github"
    namespace = "argocd"
    labels    = { "argocd.argoproj.io/secret-type" = "repository" }
  }
  data = {
    type     = "git"
    url      = "https://github.com/teststuffstash/oracle-iac.git"
    username = "git"
    password = var.argocd_github_pat
  }
  depends_on = [helm_release.argocd]
}

# ---------------------------------------------------------------------------
# 2 · Infisical bootstrap secrets (seeded here; ArgoCD/CNPG reference them by name)
#     These are NOT in git and NOT ArgoCD-managed, so ArgoCD never prunes them.
# ---------------------------------------------------------------------------
resource "kubernetes_namespace" "infisical" {
  metadata { name = "infisical" }
}

# Backend env (infisical.kubeSecretRef). ENCRYPTION_KEY + AUTH_SECRET must be stable —
# if Infisical auto-generated them they'd rotate under the data and lock you out.
resource "kubernetes_secret" "infisical_secrets" {
  metadata {
    name      = "infisical-secrets"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }
  data = {
    ENCRYPTION_KEY = var.infisical_encryption_key
    AUTH_SECRET    = var.infisical_auth_secret
    SITE_URL       = "https://infisical.teststuff.net"
  }
}

# DB connection string (postgresql.useExistingPostgresSecret → key DB_CONNECTION_URI).
resource "kubernetes_secret" "infisical_db" {
  metadata {
    name      = "infisical-db"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }
  data = { DB_CONNECTION_URI = local.infisical_db_uri }
}

# Super-admin credentials for the chart's autoBootstrap job (envFrom this secret →
# `infisical bootstrap`). Creates the first admin non-interactively instead of the
# "Create your first Super Admin Account" screen. Creds live in KeePass.
resource "kubernetes_secret" "infisical_bootstrap_credentials" {
  metadata {
    name      = "infisical-bootstrap-credentials"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }
  data = {
    INFISICAL_ADMIN_EMAIL    = var.infisical_admin_email
    INFISICAL_ADMIN_PASSWORD = var.infisical_admin_password
  }
}

# App-role password for the CNPG cluster's bootstrap (initdb.secret). basic-auth type;
# username MUST equal the initdb owner. Same password tofu used to build the URI above,
# so the two always agree.
resource "kubernetes_secret" "infisical_pg_app" {
  metadata {
    name      = "infisical-pg-app"
    namespace = kubernetes_namespace.infisical.metadata[0].name
  }
  type = "kubernetes.io/basic-auth"
  data = {
    username = "infisical"
    password = var.infisical_db_password
  }
}

# ---------------------------------------------------------------------------
# 3 · Root app-of-apps — hands control to git (argocd/platform/)
# ---------------------------------------------------------------------------
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  namespace  = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.argocd_apps_chart_version

  values = [yamlencode({
    applications = {
      platform = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = var.argocd_repo_url
          targetRevision = "master"
          path           = "argocd/platform"
          directory      = { recurse = false }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true", "ApplyOutOfSyncOnly=true"]
        }
      }
      # Root app-of-apps for the sleep stack — now sourced from the standalone **public sleep-iac
      # repo** (FU-025, docs/sleep-iac.md), not homelab's argocd/sleep/. It reconciles the three
      # child Applications in sleep-iac/apps/ (each `project: sleep`, the tenancy boundary above).
      # This root app stays platform-owned (`project: default`) and reads sleep-iac anonymously —
      # the repo is public, so no ArgoCD repository credential. A deploy is now a version-bump PR in
      # sleep-iac; homelab only owns the platform + this pointer. Child NAMES are unchanged, so the
      # source flip adopts the existing Applications/resources in place (no prune, no recreate).
      sleep = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = "https://github.com/teststuffstash/sleep-iac.git"
          targetRevision = "master"
          path           = "apps"
          directory      = { recurse = false }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true", "ApplyOutOfSyncOnly=true"]
        }
      }
      # Root app-of-apps for the oracle stack — same three-layer shape as `sleep` above
      # (docs/oracle-iac.md), sourced from the PRIVATE oracle-iac repo (read via the
      # repo-oracle-iac-github credential). Children in oracle-iac/apps/ set `project: oracle`
      # (argocd/platform/oracle-project.yaml). apps/ is a seeded skeleton until the fleet
      # publishes its first chart — an empty directory source syncs clean with zero resources.
      # ORDER MATTERS on first apply: oracle-iac must exist on GitHub with the seeded content
      # BEFORE this root app lands (FU-056) — pointing it at a missing repo just errors, but
      # never flip a root app's source ahead of its content (docs/sleep-iac.md §Risks).
      oracle = {
        namespace = "argocd"
        project   = "default"
        source = {
          repoURL        = "https://github.com/teststuffstash/oracle-iac.git"
          targetRevision = "master"
          path           = "apps"
          directory      = { recurse = false }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "argocd" }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true", "ApplyOutOfSyncOnly=true"]
        }
      }
    }
  })]

  # Needs the Application CRD installed by the argo-cd chart first.
  depends_on = [helm_release.argocd]
}

output "argocd_url" {
  value = "https://argocd.teststuff.net  (direct: http://${local.argocd_lb_ip})"
}

output "argocd_admin_password_hint" {
  value = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d  → store in KeePass"
}

output "infisical_url" {
  value = "https://infisical.teststuff.net  (direct: http://${local.infisical_lb_ip})"
}
