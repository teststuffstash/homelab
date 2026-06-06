# Mints the least-privilege `homelab-tofu-apply` write token that tofu/cloudflare/ uses.
# Two policies: zone-scoped (DNS/SSL/WAF) + account-scoped (Tunnel). Permission-group IDs
# are resolved by name so we don't hard-code opaque UUIDs. Names are URL-encoded per the
# data-source contract; scope disambiguates same-named account vs zone groups.

data "cloudflare_api_token_permission_groups_list" "dns_write" {
  name  = "DNS%20Write"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "ssl_write" {
  name  = "SSL%20and%20Certificates%20Write"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "waf_write" {
  name  = "Zone%20WAF%20Write"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "tunnel_write" {
  name  = "Cloudflare%20Tunnel%20Write"
  scope = "com.cloudflare.api.account"
}

locals {
  zone_resource    = { "com.cloudflare.api.account.zone.${var.zone_id}" = "*" }
  account_resource = { "com.cloudflare.api.account.${var.account_id}" = "*" }
}

resource "cloudflare_api_token" "tofu_apply" {
  name = var.token_name

  # Zone-scoped: DNS records, client certs / mTLS hostname assoc, WAF custom rule.
  policies = [
    {
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.dns_write.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.ssl_write.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.waf_write.result[0].id },
      ]
      resources = jsonencode(local.zone_resource)
    },
    # Account-scoped: the Cloudflare Tunnel + its remote config.
    {
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.tunnel_write.result[0].id },
      ]
      resources = jsonencode(local.account_resource)
    },
  ]

  expires_on = var.expires_on

  condition = length(var.allowed_ips) > 0 ? {
    request_ip = { in = var.allowed_ips }
  } : null
}
