# The live legacy module of Workspace sleep-tracking-garage (2026-11-25); comments and import blocks dropped,
# ids replaced by placeholders. The adopting repos[].provision entry must reproduce it exactly.
resource "garage_bucket" "sleep_band" {
  global_alias = "sleep-band"
  max_size     = 5368709120
}
resource "garage_bucket" "sleep_db" {
  global_alias = "sleep-db"
  max_size     = 2147483648
}
resource "garage_key" "band_writer" { name = "sleep-band-writer" }
resource "garage_key" "ingester"    { name = "sleep-ingester" }
resource "garage_key" "ingester_rw" { name = "sleep-ingester-rw" }
resource "garage_bucket_permission" "band_writer_write" {
  bucket_id = garage_bucket.sleep_band.id
  access_key_id = garage_key.band_writer.id
  read = true
  write = true
  owner = false
}
resource "garage_bucket_permission" "ingester_read" {
  bucket_id = garage_bucket.sleep_band.id
  access_key_id = garage_key.ingester.id
  read = true
  write = false
  owner = false
}
resource "garage_bucket_permission" "ingester_rw_readwrite" {
  bucket_id = garage_bucket.sleep_db.id
  access_key_id = garage_key.ingester_rw.id
  read = true
  write = true
  owner = false
}
output "sleep_band_bucket_id" { value = garage_bucket.sleep_band.id }
output "sleep_db_bucket_id"   { value = garage_bucket.sleep_db.id }
