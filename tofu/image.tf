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

# Longhorn-ready image: + iscsi-tools + util-linux-tools. Used by storage-tier VMs
# (nodes with longhorn=true) so the extensions are baked into the VM IMAGE. Do NOT add
# extensions to a running Proxmox VM via `talosctl upgrade` — that reboot loses the
# nocloud (cloud-init) static IP/hostname and the node rejoins as a DHCP/default-name
# ghost (learned the hard way with wk-02). Bake them in the image + recreate the VM.
resource "talos_image_factory_schematic" "longhorn" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/qemu-guest-agent",
          "siderolabs/iscsi-tools",
          "siderolabs/util-linux-tools",
        ]
      }
    }
  })
}

data "talos_image_factory_urls" "longhorn" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.longhorn.id
  platform      = "nocloud"
  architecture  = "amd64"
}

# Bare-metal install image (metal.tf `talos_install_image`). iscsi-tools + util-linux-tools
# for Longhorn, but deliberately NO qemu-guest-agent: that VM-only extension never reports
# healthy on physical hardware, so Talos's boot phase startAllServices waits on it until the
# deadline (~11 min) → "context deadline exceeded" → boot sequence fails → reboot. That was the
# chronic bare-metal flapping (root-caused 2026-06-19 via the dmesg tap). VMs keep qemu-guest-agent.
resource "talos_image_factory_schematic" "metal" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/iscsi-tools",
          "siderolabs/util-linux-tools",
        ]
      }
    }
  })
}

data "talos_image_factory_urls" "metal" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.metal.id
  platform      = "metal"
  architecture  = "amd64"
}

resource "proxmox_download_file" "talos_longhorn" {
  content_type            = "iso"
  datastore_id            = var.datastore_images
  node_name               = var.proxmox_node
  file_name               = "talos-${var.talos_version}-longhorn-nocloud-amd64.img"
  url                     = data.talos_image_factory_urls.longhorn.urls.disk_image
  decompression_algorithm = "zst"
  overwrite               = false
}
