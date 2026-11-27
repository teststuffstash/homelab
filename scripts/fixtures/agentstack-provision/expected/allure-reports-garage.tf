# The live legacy module of Workspace allure-reports-garage (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
resource "garage_bucket" "allure_reports" {
  global_alias = "allure-reports"
  max_size     = 21474836480
}
resource "garage_key" "writer" { name = "allure-reports-writer" }
resource "garage_key" "reader" { name = "allure-reports-reader" }
resource "garage_bucket_permission" "writer_rw" {
  bucket_id     = garage_bucket.allure_reports.id
  access_key_id = garage_key.writer.id
  read  = true
  write = true
  owner = false
}
resource "garage_bucket_permission" "reader_read" {
  bucket_id     = garage_bucket.allure_reports.id
  access_key_id = garage_key.reader.id
  read  = true
  write = false
  owner = false
}
resource "garage_bucket" "specs" {
  global_alias           = "oracle-specs"
  max_size               = 5368709120
  website_enabled        = true
  website_index_document = "index.html"
}
resource "garage_bucket_permission" "specs_writer_rw" {
  bucket_id     = garage_bucket.specs.id
  access_key_id = garage_key.writer.id
  read  = true
  write = true
  owner = false
}
resource "garage_bucket_permission" "specs_reader_read" {
  bucket_id     = garage_bucket.specs.id
  access_key_id = garage_key.reader.id
  read  = true
  write = false
  owner = false
}
output "bucket" {
  value = garage_bucket.allure_reports.global_alias
}
output "writer_access_key_id" {
  value = garage_key.writer.id
}
output "writer_secret_access_key" {
  value     = garage_key.writer.secret_access_key
  sensitive = true
}
output "reader_access_key_id" {
  value = garage_key.reader.id
}
output "reader_secret_access_key" {
  value     = garage_key.reader.secret_access_key
  sensitive = true
}
