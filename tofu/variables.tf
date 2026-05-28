# ---- Proxmox (infra layer) ------------------------------------------------
variable "proxmox_endpoint" {
  description = "Proxmox API endpoint, incl. scheme and port."
  type        = string
  default     = "https://192.168.2.3:8006/"
}

variable "proxmox_api_token" {
  description = "Proxmox API token 'user@realm!tokenid=uuid'. Set via TF_VAR_proxmox_api_token or SOPS — never commit."
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification (default Proxmox cert is self-signed)."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Proxmox node name."
  type        = string
  default     = "pve"
}

variable "datastore_vms" {
  description = "Datastore for VM disks."
  type        = string
  default     = "local-lvm"
}

variable "datastore_images" {
  description = "Datastore that holds downloaded images/ISOs."
  type        = string
  default     = "local"
}

variable "network_bridge" {
  description = "Proxmox bridge to attach VMs to."
  type        = string
  default     = "vmbr0"
}

# ---- Cluster (provider-agnostic layer) ------------------------------------
variable "cluster_name" {
  description = "Kubernetes / Talos cluster name."
  type        = string
  default     = "homelab"
}

variable "talos_version" {
  description = "Talos Linux version (also selects the Image Factory image)."
  type        = string
  default     = "v1.13.2"
}

variable "kubernetes_version" {
  description = "Kubernetes version to install."
  type        = string
  default     = "v1.36.1"
}

variable "gateway" {
  description = "Default gateway for the node static IPs."
  type        = string
  default     = "192.168.2.1"
}

variable "nameservers" {
  description = "DNS servers for the nodes (sorted)."
  type        = list(string)
  default     = ["192.168.2.1"]
}

# Node inventory. Map key = node/VM name (for_each over a map is deterministic).
# Keep entries sorted by key; IPs must be free / OPNsense-reserved addresses.
variable "nodes" {
  description = "Talos node inventory keyed by name."
  type = map(object({
    role      = string # "controlplane" | "worker"
    vm_id     = number
    ip_cidr   = string # e.g. "192.168.2.51/24"
    cores     = number
    memory_mb = number
    disk_gb   = number
  }))
  default = {
    cp-01 = { role = "controlplane", vm_id = 8101, ip_cidr = "192.168.2.51/24", cores = 4, memory_mb = 8192, disk_gb = 40 }
    wk-01 = { role = "worker", vm_id = 8111, ip_cidr = "192.168.2.61/24", cores = 4, memory_mb = 12288, disk_gb = 80 }
    wk-02 = { role = "worker", vm_id = 8112, ip_cidr = "192.168.2.62/24", cores = 4, memory_mb = 12288, disk_gb = 80 }
  }

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) >= 1
    error_message = "At least one controlplane node is required."
  }
}
