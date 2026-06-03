# ---- Proxmox (infra layer) ------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, incl. scheme and port."
  type        = string
  default     = "https://192.168.2.3:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token 'user@realm!tokenid=uuid'. Set via TF_VAR_proxmox_api_token — never commit."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (default Proxmox cert is self-signed)."
  type        = bool
  default     = true
}

variable "proxmox_ssh_private_key_file" {
  description = "Path to the SSH private key bpg uses to reach the Proxmox node. Lives outside the repo."
  type        = string
  default     = "/home/node/.claude/homelab-pve-ssh/id_ed25519"
}

variable "proxmox_node" {
  description = "Proxmox node name."
  type        = string
  default     = "pve"
}

variable "datastore_rootfs" {
  description = "Datastore for the container rootfs (must support 'rootdir')."
  type        = string
  default     = "local-lvm"
}

variable "ct_template" {
  description = "LXC template volume id (download first: pveam download local <tmpl>)."
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "network_bridge" {
  description = "Proxmox bridge to attach the container to."
  type        = string
  default     = "vmbr0"
}

variable "gateway" {
  description = "Default gateway."
  type        = string
  default     = "192.168.2.1"
}

variable "nameserver" {
  description = "DNS server for the container."
  type        = string
  default     = "192.168.2.1"
}

variable "ssh_public_keys" {
  description = "SSH public keys authorized for the container root user (for Ansible config-management)."
  type        = list(string)
}

# ---- Matchbox container ---------------------------------------------------
variable "matchbox_vmid" {
  description = "Proxmox CTID for the Matchbox container (cluster VMs use 81xx; keep clear of them)."
  type        = number
  default     = 210
}

variable "matchbox_hostname" {
  description = "Container hostname."
  type        = string
  default     = "matchbox"
}

variable "matchbox_ip_cidr" {
  description = "Static IP/CIDR for the Matchbox container (must be free / outside the DHCP pool)."
  type        = string
  default     = "192.168.2.30/24"
}

variable "matchbox_cores" {
  type    = number
  default = 2
}

variable "matchbox_memory_mb" {
  type    = number
  default = 1024
}

variable "matchbox_disk_gb" {
  description = "Rootfs size. Holds the Talos kernel/initramfs/disk assets served over PXE."
  type        = number
  default     = 8
}
