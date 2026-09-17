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

# One nocloud image per (schematic, version) pair a VM actually needs — two INDEPENDENT axes:
# the schematic follows the VM's `longhorn` flag (mount/serve Longhorn → iscsi-tools +
# util-linux-tools), the version follows its ROLE (variables.tf: talos_version_controlplane /
# talos_version_worker), so a Longhorn-less worker or a Longhorn control plane still boots the
# right kernel (PR#1740 review). Keys double as the file-name stem; nx02.tf downloads the same
# set on the second hypervisor so a VM definition can move between them unchanged.
locals {
  talos_role_version = {
    controlplane = var.talos_version_controlplane
    worker       = var.talos_version_worker
  }
  vm_image_key = {
    for name, n in var.nodes :
    name => "${n.longhorn ? "longhorn" : "plain"}-${local.talos_role_version[n.role]}"
  }
  vm_images = {
    for key in distinct(values(local.vm_image_key)) :
    key => {
      longhorn = startswith(key, "longhorn-")
      version  = trimprefix(trimprefix(key, "longhorn-"), "plain-")
    }
  }
}

data "talos_image_factory_urls" "vm" {
  for_each      = local.vm_images
  talos_version = each.value.version
  schematic_id  = each.value.longhorn ? talos_image_factory_schematic.longhorn.id : talos_image_factory_schematic.this.id
  platform      = "nocloud"
  architecture  = "amd64"
}

resource "proxmox_download_file" "talos" {
  for_each = local.vm_images
  # Downloaded compressed (.raw.zst) and decompressed by Proxmox into the 'iso'
  # datastore (decompression is NOT supported for the 'import' content type).
  # The VM disk then references this via `file_id` (NOT import_from — bpg requires
  # file_id for images fetched with decompression_algorithm).
  content_type            = "iso"
  datastore_id            = var.datastore_images
  node_name               = var.proxmox_node
  file_name               = "talos-${each.value.version}-${each.value.longhorn ? "longhorn-" : ""}nocloud-amd64.img"
  url                     = data.talos_image_factory_urls.vm[each.key].urls.disk_image
  decompression_algorithm = "zst"
  overwrite               = false
}

# State carry-over from the pre-split single resources (keeps cp-01's file_id KNOWN at plan time,
# else the VM would be planned for replacement). Remove both blocks in the PR that next moves a
# version — a `moved` target must exist in the for_each set.
moved {
  from = proxmox_download_file.talos
  to   = proxmox_download_file.talos["plain-v1.13.2"]
}

moved {
  from = proxmox_download_file.talos_longhorn
  to   = proxmox_download_file.talos["longhorn-v1.13.10"]
}


# Longhorn-ready schematic: + iscsi-tools + util-linux-tools. Picked by `local.vm_images` for VMs
# with longhorn=true so the extensions are baked into the VM IMAGE. Do NOT add
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
  talos_version = var.talos_version_worker
  schematic_id  = talos_image_factory_schematic.metal.id
  platform      = "metal"
  architecture  = "amd64"
}

# Metal + Kata Containers (SLSA Phase-3 / agent-CI microVM primitive, docs/slsa.md convergence
# note). Same base as `metal` plus the kata runtime — used by metal_nodes entries with
# kata = true (spike: wk-metal-03). Needs VT-x enabled in BIOS (/dev/kvm). Extra-tier
# extension: pin expectations accordingly.
resource "talos_image_factory_schematic" "metal_kata" {
  schematic = yamlencode({
    customization = {
      systemExtensions = {
        officialExtensions = [
          "siderolabs/iscsi-tools",
          "siderolabs/util-linux-tools",
          "siderolabs/kata-containers",
        ]
      }
    }
  })
}

data "talos_image_factory_urls" "metal_kata" {
  talos_version = var.talos_version_worker
  schematic_id  = talos_image_factory_schematic.metal_kata.id
  platform      = "metal"
  architecture  = "amd64"
}
