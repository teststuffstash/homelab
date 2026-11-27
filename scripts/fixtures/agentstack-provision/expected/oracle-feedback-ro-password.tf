# The live legacy module of Workspace oracle-feedback-ro-password (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
# vars: infisical_project_id=8cf9ec95-d357-4fc4-95ac-7185cb22736c
variable "infisical_project_id" { type = string }
resource "random_password" "feedback_ro" {
  length  = 32
  special = false
  keepers = { generation = "1" }
}
resource "infisical_secret" "feedback_ro_password" {
  name         = "ORACLE_FEEDBACK_PG_RO_PASSWORD"
  value        = random_password.feedback_ro.result
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/"
}
output "published_key" {
  value = infisical_secret.feedback_ro_password.name
}
