# The live legacy module of Workspace sleep-specs-garage (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
resource "garage_bucket" "sleep_specs" {
  global_alias          = "sleep-specs"
  max_size              = 1073741824
  website_enabled       = true
  website_index_document = "index.html"
}
resource "garage_key" "specs_writer" {
  name = "sleep-specs-writer"
}
resource "garage_key" "specs_reader" {
  name = "sleep-specs-reader"
}
resource "garage_bucket_permission" "writer" {
  bucket_id     = garage_bucket.sleep_specs.id
  access_key_id = garage_key.specs_writer.id
  read          = true
  write         = true
  owner         = false
}
resource "garage_bucket_permission" "reader" {
  bucket_id     = garage_bucket.sleep_specs.id
  access_key_id = garage_key.specs_reader.id
  read          = true
  write         = false
  owner         = false
}
output "bucket_id" {
  value = garage_bucket.sleep_specs.id
}
output "specs_s3_access_key_id" {
  value = garage_key.specs_writer.id
}
output "specs_s3_secret_key" {
  value     = garage_key.specs_writer.secret_access_key
  sensitive = true
}
