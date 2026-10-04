# Longhorn's BACKUP TARGET — a single-node Garage in an unprivileged LXC on nx-02 (FU-299,
# docs/longhorn-backup.md).
#
# Why it lives OUTSIDE the cluster, and in THIS root: a backup that rides Longhorn is no backup of
# Longhorn — the in-cluster Garage sits on `longhorn-local-xfs`, so a Longhorn failure (or a bad
# Longhorn upgrade, which cannot be downgraded — restore IS the rollback) would take the copies with
# the originals. Like Matchbox, the target must survive a cluster wipe, which is exactly this
# root's invariant (providers.tf: separate state, never destroyed with the cluster).
#
# Why an LXC on nx-02, not a VM: nx-02's RAM is committed (60.5/62 GiB to its VMs, 2026-10-02) and
# an LXC costs only what Garage uses; its 700 G `local-lvm` thin pool on the SA400 was empty. The
# pool is metered (`pve_lvm_thin_pool_data_percent{host="nx-02"}`, the PveThinPool* alerts).
#
# Like matchbox.tf this only creates the container shell + seeds the SSH key; Garage itself
# (binary, config, layout, bucket, key) is ansible/garage-backup.yml.
provider "proxmox" {
  alias     = "nx02"
  endpoint  = var.nx02_endpoint
  api_token = var.nx02_api_token # KeePass `nx-02-api-token-tofu`, exported by scripts/keepass-env.sh
  insecure  = var.proxmox_insecure

  ssh {
    agent       = false
    username    = "root"
    private_key = file(var.proxmox_ssh_private_key_file)
  }
}

resource "proxmox_virtual_environment_container" "backup_garage" {
  provider      = proxmox.nx02
  node_name     = var.nx02_node
  vm_id         = var.backup_garage_vmid
  unprivileged  = true
  start_on_boot = true
  tags          = ["backup", "garage"]

  cpu {
    cores = 2
  }

  memory {
    dedicated = var.backup_garage_memory_mb
    swap      = 512
  }

  # ONE rootfs holds OS + Garage meta + data. Thin-provisioned: the pool only pays for what the
  # backups write, and `discard` below hands deletes back. Sizing + growth: docs/longhorn-backup.md.
  disk {
    datastore_id  = var.nx02_datastore_rootfs
    size          = var.backup_garage_disk_gb
    mount_options = ["discard"]
  }

  operating_system {
    # The same Debian 12 template as Matchbox, already present on nx-02's `local` storage.
    template_file_id = var.ct_template
    type             = "debian"
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  initialization {
    hostname = "backup-garage"

    ip_config {
      ipv4 {
        address = var.backup_garage_ip_cidr
        gateway = var.gateway
      }
    }

    dns {
      servers = [var.nameserver]
    }

    user_account {
      keys = var.ssh_public_keys
    }
  }

  # systemd in an unprivileged container needs nesting for cgroup/namespace setup (as Matchbox).
  features {
    nesting = true
  }
}
