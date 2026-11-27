# The live legacy module of Workspace ert-whatif-garage (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
resource "garage_bucket" "ert_whatif" {
  global_alias = "ert-whatif"
  max_size     = 4294967296
}
resource "garage_bucket" "ert_whatif_control" {
  global_alias = "ert-whatif-control"
  max_size     = 19327352832
}
resource "garage_bucket" "ert_whatif_candidate" {
  global_alias = "ert-whatif-candidate"
  max_size     = 19327352832
}
data "garage_bucket" "ert_snapshots" {
  global_alias = "ert-snapshots"
}
resource "garage_key" "runner" { name = "ert-whatif-runner" }
resource "garage_bucket_permission" "runner_whatif_rw" {
  bucket_id     = garage_bucket.ert_whatif.id
  access_key_id = garage_key.runner.id
  read  = true
  write = true
  owner = false
}
resource "garage_bucket_permission" "runner_control_rw" {
  bucket_id     = garage_bucket.ert_whatif_control.id
  access_key_id = garage_key.runner.id
  read  = true
  write = true
  owner = false
}
resource "garage_bucket_permission" "runner_candidate_rw" {
  bucket_id     = garage_bucket.ert_whatif_candidate.id
  access_key_id = garage_key.runner.id
  read  = true
  write = true
  owner = false
}
resource "garage_bucket_permission" "runner_snapshots_read" {
  bucket_id     = data.garage_bucket.ert_snapshots.id
  access_key_id = garage_key.runner.id
  read  = true
  write = false
  owner = false
}
output "bucket" {
  value = garage_bucket.ert_whatif.global_alias
}
output "control_bucket" {
  value = garage_bucket.ert_whatif_control.global_alias
}
output "candidate_bucket" {
  value = garage_bucket.ert_whatif_candidate.global_alias
}
output "snapshot_bucket" {
  value = data.garage_bucket.ert_snapshots.global_alias
}
output "runner_access_key_id" {
  value = garage_key.runner.id
}
output "runner_secret_access_key" {
  value     = garage_key.runner.secret_access_key
  sensitive = true
}
