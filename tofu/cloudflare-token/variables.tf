# Non-secret identifiers (account/zone IDs are not credentials). The actual tokens
# only ever travel through the CLOUDFLARE_API_TOKEN env var, never tfvars/git.
variable "account_id" {
  type        = string
  description = "Cloudflare account ID."
  default     = "07b08646b26bb43cd3073826f43b73da"
}

variable "zone_id" {
  type        = string
  description = "teststuff.net zone ID — the write token is scoped to this zone."
  default     = "6b63f95592a9e036f8b8f6934511d321"
}

variable "ingress_zone_ids" {
  type        = map(string)
  description = "Zones the INGRESS-WRITE token may edit (PublicRoute/product zones, ADR-101) — name => zone id. The tofu_apply token stays single-zone (var.zone_id); this list is the ingress credential's blast radius, add a line per onboarded product zone."
  default = {
    "teststuff.net" = "6b63f95592a9e036f8b8f6934511d321"
    "minutark.ee"   = "fa1b02951c29ee4828b8948d0dd7baaf"
  }
}

variable "token_name" {
  type    = string
  default = "homelab-tofu-apply"
}

variable "expires_on" {
  type        = string
  description = "RFC3339 expiry. Rotate before this date."
  default     = "2027-01-01T00:00:00Z"
}

variable "allowed_ips" {
  type        = list(string)
  description = "Optional CIDR allow-list (e.g. your egress IP) pinning where the token may be used. Empty = no IP restriction."
  default     = []
}

variable "user_id" {
  type        = string
  description = "Cloudflare user id (user-scoped policies: FU-156 inventory-read + jail-read-all). Empty = those tokens not minted."
  # Settled 2026-08-12 from the legacy "Read all resources" token's own user policy
  # (uploads/step3.json — the operator's admin-token dump); a user id is a non-secret
  # identifier, same class as account_id/zone_id above. Setting it un-stages the FU-156
  # inventory-read mint on the next apply, deliberately.
  default = "8a359786af8c19d1798fa532026e0860"
}
