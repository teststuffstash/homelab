# All values are supplied by apply.sh (token + org from the live instance via the
# bootstrap secret; host via a kubectl port-forward). Nothing here is committed.
variable "infisical_host" {
  description = "Infisical API base (a localhost port-forward, set by apply.sh)."
  type        = string
}

variable "infisical_token" {
  description = "Instance-admin machine-identity token (from the bootstrap secret). Provider auth."
  type        = string
  sensitive   = true
}

variable "infisical_org_id" {
  description = "Org UUID the identity is created in (derived from the token by apply.sh)."
  type        = string
}

variable "kubeconfig" {
  description = "Path to the cluster kubeconfig (to write the ESO credential secret)."
  type        = string
  default     = "../kubeconfig"
}

variable "admin_username" {
  description = "Super-admin email — added to the homelab project as admin (so it's a member, not just org). From KeePass via apply.sh."
  type        = string
  default     = "admin@teststuff.net"
}
