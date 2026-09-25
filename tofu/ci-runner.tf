# CI runner VM (ADR-082) — a Debian cloud-init VM on Proxmox that registers as a self-hosted
# GitHub Actions runner. It runs the full-stack confidence gate (`devbox run test-integration`:
# k3d + Garage + ingester + Grafana + Playwright) per PR. A real VM kernel (not a nested ARC pod)
# is what lets k3d's privileged node containers run without DinD gymnastics.
#
# DURABLE path (ADR-081): no hand-pasted token. Cloud-init carries a GitHub App key + the minting
# script and mints a FRESH runner registration token at every boot (self-registering, reproducible
# from `tofu apply`). The App key is stable, so the cloud-init snippet is stable — no perpetual diff.
#
# NOT a Talos node — general Debian + Docker. nix/devbox/k3d come from the workflow at run time
# (same single-user-nix flow as the ARC runners, see homelab docs/ci.md).
#
# SAFETY: this hits live Proxmox. `devbox run -- tofu -chdir=tofu plan` and review before apply.
# HOST PREREQUISITE (not tofu-managed — Proxmox storage config): 'snippets' must be enabled on
# var.datastore_images on EACH hypervisor that hosts a runner, or the cloud-init upload fails:
#   pvesm set local --content import,backup,vztmpl,iso,snippets   # = the existing list + snippets
# (pve had it from before this was written down; nx-02 was set 2026-09-21 for ci-runner-02.)
#
# TWO runners, one per hypervisor (FU-266): ci-runner-01 on pve, ci-runner-02 on nx-02 — same
# labels, so a pve outage is no longer a CI outage. The nx-02 blocks at the bottom are a literal
# near-copy for the same reason as nx02.tf: a provider cannot be chosen per for_each key.

variable "ci_runner_enabled" {
  description = "Toggle the CI runner VM. On — the runner-registrar App is live (ADR-082)."
  type        = bool
  default     = true
}

variable "ci_runner_vm_id" {
  type    = number
  default = 9001
}

variable "ci_runner_ip_cidr" {
  description = "Static IP/CIDR on the LAN (free between .54 metal and .61 worker)."
  type        = string
  default     = "192.168.2.55/24"
}

variable "ci_runner_cores" {
  type    = number
  default = 6
}

variable "ci_runner_memory_mb" {
  type    = number
  default = 12288 # 2 concurrent kind e2es (runner slots 1+2, operator 2026-08-08) — one run's
  # true working set is ~2G + docker/kind cache; 12G was mostly page cache (9.9G available
  # measured mid-run). 6 cores at 17–26% were wasted on a single slot. 16G→12G 2026-09-08:
  # idle read 1.5G used / 8.7G cache / 14.4G available — the 4G funds wk-03's ARC headroom
  # (variables.tf); the e2e p50 is sequencing-bound (PSI ~0), not memory-bound.
}

variable "ci_runner_02_running" {
  description = "ci-runner-02's power state (started + on_boot). PARKED false 2026-09-25 (operator) while nx-02's NUMA/swap placement is investigated — FU-289; the VM and its disk stay, ci-runner-01 carries the proxmox-vm lane. Flip back to true to resume."
  type        = bool
  default     = false
}

variable "ci_runner_02_vm_id" {
  type    = number
  default = 9002
}

variable "ci_runner_02_ip_cidr" {
  description = "ci-runner-02's static IP/CIDR — after cp-02 (.65) in the .51–.99 servers range (docs/ip-plan.md)."
  type        = string
  default     = "192.168.2.66/24"
}

variable "ci_runner_disk_gb" {
  type    = number
  default = 80
}

variable "ci_runner_debian_image_url" {
  type    = string
  default = "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
}

variable "ci_runner_ssh_authorized_key" {
  description = "Public key for the debian user (SSH access to debug the runner). Public — safe in git."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINZKZigIKq16Vbbd2sthyXbfFtrkAP/3IdO7r1AluePz rasmus@forgejo.teststuff.net"
}

# --- GitHub App (runner registrar) — the durable registration path -----------------------------
variable "github_runner_org" {
  type    = string
  default = "teststuffstash"
}

variable "github_runner_labels" {
  type    = string
  default = "proxmox-vm,k3d,integration"
}

variable "github_runner_version" {
  description = "actions/runner release (check github.com/actions/runner/releases)."
  type        = string
  default     = "2.323.0"
}

variable "github_app_id" {
  description = "Numeric App ID of the runner-registrar GitHub App. Not a secret (the .pem is)."
  type        = string
  default     = "4141567"
}

variable "github_app_installation_id" {
  description = "Installation ID of that App on the org. Not a secret."
  type        = string
  default     = "142515626"
}

variable "github_app_private_key_file" {
  description = "Path to the App private key (.pem), out-of-repo (e.g. ~/.claude/homelab-runner-app/)."
  type        = string
  default     = "/home/node/.claude/homelab-runner-app/private-key.pem"
}

# Debian cloud image. NOTE: if Proxmox rejects a .qcow2 under the 'iso' content type, switch
# content_type to "import" (Proxmox 8.2+) and enable that content type on the datastore.
resource "proxmox_download_file" "debian_cloud" {
  count        = var.ci_runner_enabled ? 1 : 0
  content_type = "iso"
  datastore_id = var.datastore_images
  node_name    = var.proxmox_node
  file_name    = "debian-12-genericcloud-amd64.img"
  url          = var.ci_runner_debian_image_url
  overwrite    = false
}

# cloud-init user-data: drop the App key + minting script, mint a registration token at boot,
# register the runner as a systemd service. (Requires 'snippets' enabled on var.datastore_images.)
resource "proxmox_virtual_environment_file" "ci_runner_cloud_init" {
  count        = var.ci_runner_enabled ? 1 : 0
  content_type = "snippets"
  datastore_id = var.datastore_images
  node_name    = var.proxmox_node

  source_raw {
    file_name = "ci-runner-cloud-init.yaml"
    data = templatefile("${path.module}/templates/ci-runner-cloud-init.yaml.tftpl", {
      name            = "ci-runner-01"
      ssh_key         = var.ci_runner_ssh_authorized_key
      app_private_key = file(var.github_app_private_key_file)
      mint_script     = file("${path.module}/../scripts/gh-app-runner-token.sh")
      app_id          = var.github_app_id
      installation_id = var.github_app_installation_id
      org             = var.github_runner_org
      labels          = var.github_runner_labels
      runner_version  = var.github_runner_version
    })
  }
}

resource "proxmox_virtual_environment_vm" "ci_runner" {
  count     = var.ci_runner_enabled ? 1 : 0
  name      = "ci-runner-01"
  vm_id     = var.ci_runner_vm_id
  node_name = var.proxmox_node
  tags      = sort(["ci", "github-runner", "debian"])

  agent { enabled = true }

  cpu {
    cores = var.ci_runner_cores
    type  = "host"
  }

  memory {
    dedicated = var.ci_runner_memory_mb
  }

  disk {
    datastore_id = var.datastore_vms
    file_id      = proxmox_download_file.debian_cloud[0].id
    interface    = "scsi0"
    size         = var.ci_runner_disk_gb
    # local-lvm is LVM-thin → raw is the ONLY format; Proxmox silently ignores qcow2 here,
    # so declaring it drifts forever.
    file_format = "raw"
    # discard=on (2026-08-18) — same thin-pool reclaim fix as proxmox.tf; effective at next
    # power-cycle + an in-guest fstrim.
    discard = "on"
    ssd     = true
  }

  network_device {
    bridge = var.network_bridge
  }

  # Serial console (codifies the manual `qm set --serial0 socket`) — Debian cloud images log to
  # ttyS0, so this is how you `qm terminal 9001` to watch boot / catch a panic.
  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id      = var.datastore_vms
    user_data_file_id = proxmox_virtual_environment_file.ci_runner_cloud_init[0].id

    ip_config {
      ipv4 {
        address = var.ci_runner_ip_cidr
        gateway = var.gateway
      }
    }

    dns {
      servers = var.nameservers
    }
  }
}

# ---- ci-runner-02 on nx-02 (FU-266) — same shape, the nx02 provider ---------------------------
resource "proxmox_download_file" "debian_cloud_nx02" {
  count        = var.ci_runner_enabled ? 1 : 0
  provider     = proxmox.nx02
  content_type = "iso"
  datastore_id = var.datastore_images
  node_name    = var.nx02_node
  file_name    = "debian-12-genericcloud-amd64.img"
  url          = var.ci_runner_debian_image_url
  overwrite    = false
}

resource "proxmox_virtual_environment_file" "ci_runner_02_cloud_init" {
  count        = var.ci_runner_enabled ? 1 : 0
  provider     = proxmox.nx02
  content_type = "snippets"
  datastore_id = var.datastore_images
  node_name    = var.nx02_node

  source_raw {
    file_name = "ci-runner-02-cloud-init.yaml"
    data = templatefile("${path.module}/templates/ci-runner-cloud-init.yaml.tftpl", {
      name            = "ci-runner-02"
      ssh_key         = var.ci_runner_ssh_authorized_key
      app_private_key = file(var.github_app_private_key_file)
      mint_script     = file("${path.module}/../scripts/gh-app-runner-token.sh")
      app_id          = var.github_app_id
      installation_id = var.github_app_installation_id
      org             = var.github_runner_org
      labels          = var.github_runner_labels
      runner_version  = var.github_runner_version
    })
  }
}

resource "proxmox_virtual_environment_vm" "ci_runner_02" {
  count     = var.ci_runner_enabled ? 1 : 0
  provider  = proxmox.nx02
  name      = "ci-runner-02"
  vm_id     = var.ci_runner_02_vm_id
  node_name = var.nx02_node
  started   = var.ci_runner_02_running
  on_boot   = var.ci_runner_02_running
  tags      = sort(["ci", "github-runner", "debian"])

  agent { enabled = true }

  # nx-02 is dual-socket — the nx02.tf reasoning: guest topology matches the host's so Linux keeps
  # a task's memory on its own NUMA node. `cores` is per socket.
  cpu {
    cores   = var.ci_runner_cores / 2
    sockets = 2
    numa    = true
    type    = "host"
  }

  memory {
    dedicated = var.ci_runner_memory_mb
  }

  disk {
    # The Micron NVMe thin pool (never the WD spinner local-lvm) — docker image + kind layers.
    datastore_id = var.nx02_datastore_vms
    file_id      = proxmox_download_file.debian_cloud_nx02[0].id
    interface    = "scsi0"
    size         = var.ci_runner_disk_gb
    file_format  = "raw"
    discard      = "on"
    ssd          = true
  }

  network_device {
    bridge = var.network_bridge
  }

  serial_device {}

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id      = var.nx02_datastore_vms
    user_data_file_id = proxmox_virtual_environment_file.ci_runner_02_cloud_init[0].id

    ip_config {
      ipv4 {
        address = var.ci_runner_02_ip_cidr
        gateway = var.gateway
      }
    }

    dns {
      servers = var.nameservers
    }
  }
}
