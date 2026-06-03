# Matchbox provisioning host — an unprivileged Debian 12 LXC on Proxmox.
#
# Why an LXC (not a k8s pod / not a VM): it must be always-on with the hypervisor
# and survive `tofu destroy` of the cluster, with no bootstrap loop (the thing that
# PXE-installs nodes can't live inside the cluster it installs). An LXC boots with
# Proxmox, before the bare-metal fleet comes online — exactly the assumed boot order.
#
# This module only creates the container shell + injects an SSH key. Matchbox itself
# (binary, systemd unit, TLS, assets) is installed by ansible/matchbox.yml — keeping
# config-management in the tool already used for the rest of the fleet.
resource "proxmox_virtual_environment_container" "matchbox" {
  node_name     = var.proxmox_node
  vm_id         = var.matchbox_vmid
  unprivileged  = true
  start_on_boot = true
  tags          = ["provisioning", "matchbox"]

  cpu {
    cores = var.matchbox_cores
  }

  memory {
    dedicated = var.matchbox_memory_mb
    swap      = 512
  }

  disk {
    datastore_id = var.datastore_rootfs
    size         = var.matchbox_disk_gb
  }

  operating_system {
    template_file_id = var.ct_template
    type             = "debian"
  }

  network_interface {
    name   = "eth0"
    bridge = var.network_bridge
  }

  initialization {
    hostname = var.matchbox_hostname

    ip_config {
      ipv4 {
        address = var.matchbox_ip_cidr
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

  # systemd in an unprivileged container needs nesting for cgroup/namespace setup.
  features {
    nesting = true
  }
}
