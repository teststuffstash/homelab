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
