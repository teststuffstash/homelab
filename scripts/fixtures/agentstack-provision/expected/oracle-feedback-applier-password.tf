# The live legacy module of Workspace oracle-feedback-applier-password (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
# vars: infisical_project_id=00000000-0000-4000-8000-000000000000
variable "infisical_project_id" { type = string }
resource "random_password" "feedback_applier" {
  length  = 32
  special = false
  keepers = { generation = "1" }
}
resource "infisical_secret" "feedback_applier_password" {
  name         = "ORACLE_FEEDBACK_PG_APPLIER_PASSWORD"
  value        = random_password.feedback_applier.result
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/"
}
output "published_key" {
  value = infisical_secret.feedback_applier_password.name
}
