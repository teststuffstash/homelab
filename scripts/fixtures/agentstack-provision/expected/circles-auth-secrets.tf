# The live legacy module of Workspace circles-auth-secrets (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
resource "random_password" "encryption_key" {
  length  = 48
  special = false
  lifecycle { prevent_destroy = true }
}
resource "random_password" "static_api_key" {
  length  = 48
  special = false
  keepers = { generation = "1" }
}
resource "random_password" "oidc_client_secret" {
  length  = 48
  special = false
  keepers = { generation = "1" }
}
resource "random_password" "cookie_secret" {
  length  = 32
  special = false
  keepers = { generation = "1" }
}
output "encryption_key" {
  value     = random_password.encryption_key.result
  sensitive = true
}
output "static_api_key" {
  value     = random_password.static_api_key.result
  sensitive = true
}
output "oidc_client_secret" {
  value     = random_password.oidc_client_secret.result
  sensitive = true
}
output "cookie_secret" {
  value     = random_password.cookie_secret.result
  sensitive = true
}
