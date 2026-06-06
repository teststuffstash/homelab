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
  description = "Public name for Home Assistant via the tunnel."
  default     = "ha.teststuff.net"
}

variable "ha_service" {
  type        = string
  description = <<-EOT
    In-cluster origin cloudflared forwards to (the HA ClusterIP service).
    NOTE the TRAILING DOT — it forces an absolute FQDN so the Go resolver skips the pod's
    search domains. Without it, ndots:5 makes cloudflared append `teststuff.net`, producing
    `…svc.cluster.local.teststuff.net`, which matches the `*.local.teststuff.net -> 127.0.0.1`
    wildcard and makes cloudflared dial its own loopback (502).
  EOT
  default     = "http://home-assistant.home-assistant.svc.cluster.local.:8123"
}

variable "cloudflared_image" {
  type        = string
  description = "Pinned by digest (repo convention). cloudflared 2026.5.2."
  default     = "cloudflare/cloudflared:2026.5.2@sha256:12ff5c6992a9863db4da270746af7c244bcaee49353039af8104268a18d6c4f0"
}

variable "cloudflared_replicas" {
  type    = number
  default = 2
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
