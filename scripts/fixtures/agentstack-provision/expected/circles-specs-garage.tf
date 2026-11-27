# The live legacy module of Workspace circles-specs-garage (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
resource "garage_key" "writer" { name = "circles-specs-writer" }
resource "garage_key" "reader" { name = "circles-specs-reader" }
resource "garage_bucket" "specs" {
  global_alias           = "circles-specs"
  max_size               = 1073741824
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
  value = garage_bucket.specs.global_alias
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
