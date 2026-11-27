# The live legacy module of Workspace snore-recorder-garage (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
# vars: infisical_project_id=8cf9ec95-d357-4fc4-95ac-7185cb22736c ingester_access_key_id=GK000000000000000000000001
variable "ingester_access_key_id" { type = string }
variable "infisical_project_id" { type = string }
resource "garage_bucket" "sleep_snore" {
  global_alias = "sleep-snore"
  max_size     = 5368709120
}
resource "garage_key" "snore_writer" {
  name = "sleep-snore-writer"
}
resource "garage_bucket_permission" "writer" {
  bucket_id     = garage_bucket.sleep_snore.id
  access_key_id = garage_key.snore_writer.id
  read          = false
  write         = true
  owner         = false
}
resource "garage_bucket_permission" "ingester_read" {
  bucket_id     = garage_bucket.sleep_snore.id
  access_key_id = var.ingester_access_key_id
  read          = true
  write         = false
  owner         = false
}
resource "infisical_secret" "snore_akid" {
  name         = "SNORE_S3_ACCESS_KEY_ID"
  value        = garage_key.snore_writer.id
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/"
}
resource "infisical_secret" "snore_sk" {
  name         = "SNORE_S3_SECRET_KEY"
  value        = garage_key.snore_writer.secret_access_key
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/"
}
output "bucket_id" {
  value = garage_bucket.sleep_snore.id
}
output "snore_s3_access_key_id" {
  value = garage_key.snore_writer.id
}
output "snore_s3_secret_key" {
  value     = garage_key.snore_writer.secret_access_key
  sensitive = true
}
