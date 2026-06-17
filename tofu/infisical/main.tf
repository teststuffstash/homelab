# Infisical content-as-code — closes the ESO loop declaratively (the day-1.5 step).
#
# Authenticates as the bootstrap-created **Instance Admin Identity** (token auth; the
# token is non-expiring and lives in the in-cluster `infisical-bootstrap-secret`, read
# by apply.sh). From there it creates, in git:
#   * the `homelab` project (+ default dev/staging/prod envs),
#   * an `eso-reader` Universal-Auth machine identity scoped to read that project,
#   * the ESO credential secret in the cluster (clientId/clientSecret),
#   * a demo secret proving the Infisical -> ESO -> k8s Secret chain.
#
# State is LOCAL + gitignored (it holds the client secret). Run via ./apply.sh.

provider "infisical" {
  host = var.infisical_host
  auth = {
    token = var.infisical_token
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig
}

resource "infisical_project" "homelab" {
  name = "homelab"
  slug = "homelab"
  # should_create_default_envs defaults true -> dev/staging/prod (we use prod)
}

# The identity ESO authenticates as. No org-wide rights ("no-access"); project access
# is granted by the membership below (least privilege).
resource "infisical_identity" "eso" {
  name   = "eso-reader"
  org_id = var.infisical_org_id
  role   = "no-access"
}

resource "infisical_identity_universal_auth" "eso" {
  identity_id = infisical_identity.eso.id
}

resource "infisical_identity_universal_auth_client_secret" "eso" {
  identity_id = infisical_identity.eso.id
  description = "ESO ClusterSecretStore (read homelab/prod)"
  depends_on  = [infisical_identity_universal_auth.eso]
}

# Read-only on the homelab project.
resource "infisical_project_identity" "eso" {
  project_id  = infisical_project.homelab.id
  identity_id = infisical_identity.eso.id
  roles       = [{ role_slug = "viewer" }]
}

# Add the super admin as a project member (admin). Org membership doesn't grant project
# access in Infisical, and the project was created by a machine identity — so without this
# the admin sees "Join as Admin" instead of being a member. The user must already exist
# (created by autoBootstrap).
resource "infisical_project_user" "admin" {
  project_id = infisical_project.homelab.id
  username   = var.admin_username
  roles      = [{ role_slug = "admin" }]
}

# The one secret that closes the loop: ESO's UA credentials. The ClusterSecretStore
# (argocd/resources/extras/clustersecretstore.yaml) references this by name. Created
# here so it's never in git; rotates by re-applying.
resource "kubernetes_secret" "eso_machine_identity" {
  metadata {
    name      = "infisical-machine-identity"
    namespace = "external-secrets"
  }
  data = {
    clientId     = infisical_identity_universal_auth_client_secret.eso.client_id
    clientSecret = infisical_identity_universal_auth_client_secret.eso.client_secret
  }
}

# Write identity for Crossplane provider-terraform: lets app Workspaces publish their
# generated keys into Infisical (e.g. snore-recorder's write key). Project "member" role
# (read+write secrets). Creds land in a crossplane-system secret the provider pod reads.
resource "infisical_identity" "tf_writer" {
  name   = "crossplane-tf-writer"
  org_id = var.infisical_org_id
  role   = "no-access"
}

resource "infisical_identity_universal_auth" "tf_writer" {
  identity_id = infisical_identity.tf_writer.id
}

resource "infisical_identity_universal_auth_client_secret" "tf_writer" {
  identity_id = infisical_identity.tf_writer.id
  description = "Crossplane provider-terraform publishes app keys to Infisical"
  depends_on  = [infisical_identity_universal_auth.tf_writer]
}

resource "infisical_project_identity" "tf_writer" {
  project_id  = infisical_project.homelab.id
  identity_id = infisical_identity.tf_writer.id
  roles       = [{ role_slug = "member" }] # read+write secrets
}

resource "kubernetes_secret" "tf_writer" {
  metadata {
    name      = "infisical-tf-writer"
    namespace = "crossplane-system"
  }
  data = {
    clientId     = infisical_identity_universal_auth_client_secret.tf_writer.client_id
    clientSecret = infisical_identity_universal_auth_client_secret.tf_writer.client_secret
  }
}

# Demo secret to prove the chain end-to-end (homelab/prod /DEMO_PING). The example
# ExternalSecret in argocd/resources/extras/ pulls this into a k8s Secret.
resource "infisical_secret" "demo_ping" {
  name         = "DEMO_PING"
  value        = "pong-from-infisical"
  env_slug     = "prod"
  workspace_id = infisical_project.homelab.id
  folder_path  = "/"
}

output "eso_client_id" {
  description = "ESO machine-identity client id (not secret)."
  value       = infisical_identity_universal_auth_client_secret.eso.client_id
}

output "next" {
  value = "ClusterSecretStore 'infisical' should go Ready; demo: kubectl -n secrets-demo get secret demo-ping"
}
