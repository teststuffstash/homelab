# The live legacy module of Workspace circles-source-garage (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
resource "garage_key" "writer" { name = "circles-source-writer" }
resource "garage_key" "reader" { name = "circles-source-reader" }
resource "garage_bucket" "source" {
  global_alias = "circles-source"
  max_size     = 67108864
}
resource "garage_bucket_permission" "source_writer_rw" {
  bucket_id     = garage_bucket.source.id
  access_key_id = garage_key.writer.id
  read  = true
  write = true
  owner = false
}
resource "garage_bucket_permission" "source_reader_read" {
  bucket_id     = garage_bucket.source.id
  access_key_id = garage_key.reader.id
  read  = true
  write = false
  owner = false
}
output "bucket" {
  value = garage_bucket.source.global_alias
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
