# Talos Image Factory: bake a nocloud disk image with the qemu-guest-agent
# extension (so Proxmox sees the guest agent), then download it to the node.
resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent",
        ]
      }
    }
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
  architecture  = "amd64"
}

resource "proxmox_download_file" "talos" {
  # Downloaded compressed (.raw.zst) and decompressed by Proxmox into the 'iso'
  # datastore (decompression is NOT supported for the 'import' content type).
  # The VM disk then references this via `file_id` (NOT import_from — bpg requires
  # file_id for images fetched with decompression_algorithm).
  content_type            = "iso"
  datastore_id            = var.datastore_images
  node_name               = var.proxmox_node
  file_name               = "talos-${var.talos_version}-nocloud-amd64.img"
  url                     = data.talos_image_factory_urls.this.urls.disk_image
  decompression_algorithm = "zst"
  overwrite               = false
}
