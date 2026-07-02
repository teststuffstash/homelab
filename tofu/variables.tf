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

variable "proxmox_ssh_private_key_file" {
  description = "Path to the SSH private key bpg uses to reach the Proxmox node (disk import). Lives outside the repo."
  type        = string
  default     = "/home/node/.claude/homelab-pve-ssh/id_ed25519"
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

variable "cilium_version" {
  description = "Cilium chart/version (CNI)."
  type        = string
  default     = "1.19.1"
}

variable "kube_prometheus_stack_version" {
  description = "prometheus-community/kube-prometheus-stack chart version (Prometheus + Grafana + Alertmanager + operator)."
  type        = string
  default     = "86.1.0"
}

variable "ha_prometheus_token" {
  description = "Home Assistant long-lived access token for /api/prometheus scraping. Set via TF_VAR_ha_prometheus_token — never commit. Create in HA: Profile → Security → Long-lived access tokens."
  type        = string
  sensitive   = true
}

variable "grafana_admin_password" {
  description = "Grafana admin password. Set via TF_VAR_grafana_admin_password — never commit."
  type        = string
  sensitive   = true
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
    longhorn  = optional(bool, false) # storage-tier VM -> boot the iscsi/util-linux image
  }))
  default = {
    cp-01 = { role = "controlplane", vm_id = 8101, ip_cidr = "192.168.2.51/24", cores = 4, memory_mb = 8192, disk_gb = 40 }
    wk-01 = { role = "worker", vm_id = 8111, ip_cidr = "192.168.2.61/24", cores = 4, memory_mb = 12288, disk_gb = 80, longhorn = true }
    wk-02 = { role = "worker", vm_id = 8112, ip_cidr = "192.168.2.62/24", cores = 4, memory_mb = 12288, disk_gb = 80, longhorn = true }
  }

  validation {
    condition     = length([for n in var.nodes : n if n.role == "controlplane"]) >= 1
    error_message = "At least one controlplane node is required."
  }
}

# ---- ArgoCD + Infisical bootstrap (the GitOps seam, tofu/argocd.tf) --------
# These are Tier-0/1 bootstrap secrets sourced from the KeePass wallet, not the
# cluster (the cluster can't decrypt them for itself yet — Infisical+ESO is what
# closes that loop). Load them with:  source scripts/keepass-env.sh

variable "argocd_chart_version" {
  description = "argo-cd Helm chart version (argoproj.github.io/argo-helm)."
  type        = string
  default     = "9.5.21"
}

variable "argocd_apps_chart_version" {
  description = "argocd-apps Helm chart version (root app-of-apps)."
  type        = string
  default     = "2.0.5"
}

variable "argocd_repo_url" {
  description = "Git source ArgoCD reconciles from. GitHub during bootstrap; cut over to Forgejo later (FU-007)."
  type        = string
  default     = "https://github.com/teststuffstash/homelab.git"
}

variable "argocd_github_pat" {
  description = "Fine-grained GitHub PAT (read-only contents) so ArgoCD can pull the private homelab repo. From KeePass."
  type        = string
  sensitive   = true
}

variable "infisical_encryption_key" {
  description = "Infisical ENCRYPTION_KEY (32 hex chars / 128-bit). From KeePass; never auto-generate in the cluster (would rotate under it)."
  type        = string
  sensitive   = true
}

variable "infisical_auth_secret" {
  description = "Infisical AUTH_SECRET (base64). From KeePass."
  type        = string
  sensitive   = true
}

variable "infisical_db_password" {
  description = "Password for the Infisical Postgres app role. tofu sets it on the CNPG cluster AND builds the connection string from it. From KeePass."
  type        = string
  sensitive   = true
}

variable "infisical_admin_email" {
  description = "Infisical super-admin email — created declaratively by the chart's autoBootstrap job. From KeePass."
  type        = string
  default     = "admin@teststuff.net"
}

variable "infisical_admin_password" {
  description = "Infisical super-admin password. From KeePass; consumed by the autoBootstrap job via the bootstrap-credentials secret."
  type        = string
  sensitive   = true
}
