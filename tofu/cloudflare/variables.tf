variable "account_id" {
  type    = string
  default = "07b08646b26bb43cd3073826f43b73da"
}

variable "zone_id" {
  type    = string
  default = "6b63f95592a9e036f8b8f6934511d321" # teststuff.net
}

variable "zone_name" {
  type    = string
  default = "teststuff.net"
}

variable "ha_hostname" {
  type        = string
  description = "Home Assistant's public name — the mTLS hostname association (the claim in argocd/resources/ha-publicroute/ serves it)."
  default     = "ha.teststuff.net"
}

variable "client_cert_common_name" {
  type        = string
  description = "CN on the phone's client certificate."
  default     = "homelab-phone"
}

variable "client_cert_validity_days" {
  type    = number
  default = 3650
}
