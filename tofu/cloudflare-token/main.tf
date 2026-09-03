# Mints the least-privilege `homelab-tofu-apply` write token that tofu/cloudflare/ uses.
# Two policies: zone-scoped (DNS/SSL/WAF/Settings/Single Redirects) + account-scoped (Tunnel). Permission-group IDs
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

# Zone Settings Write (2026-08-09, oracle-iac#351): the zone BOOTSTRAP (min TLS floor,
# always-use-https) is settings, not records — dns/ssl/waf write cover none of it.
data "cloudflare_api_token_permission_groups_list" "zone_settings_write" {
  name  = "Zone%20Settings%20Write"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "waf_write" {
  name  = "Zone%20WAF%20Write"
  scope = "com.cloudflare.api.account.zone"
}

# G-G (homelab goal #1302, 2026-09-03): the PublicRoute profiles render zone-phase rulesets and
# RUM through cf-api-proxy with THIS token. First live consumer-profile apply (oracle-iac#530)
# 403'd at Cloudflare ("Authentication error", code 10000) — the proxy allowlist had been
# widened (acceptance item 5), the token never was. Cache Settings Write = http_request_cache_settings
# (consumer); Zone WAF Write (existing data source) = http_ratelimit + http_request_firewall_*;
# Zone Transform Rules Write = http_response_headers_transform (api CORS headers).
data "cloudflare_api_token_permission_groups_list" "cache_settings_write" {
  name  = "Cache%20Settings%20Write"
  scope = "com.cloudflare.api.account.zone"
}
data "cloudflare_api_token_permission_groups_list" "zone_transform_rules_write" {
  name  = "Zone%20Transform%20Rules%20Write"
  scope = "com.cloudflare.api.account.zone"
}

# Single Redirects (2026-09-03, www.minutark.ee → apex): the zone bootstrap's redirect ruleset
# lives in the http_request_dynamic_redirect phase, which none of the groups above unlock — the
# docs' broad "at least one of" list notwithstanding, a POST with this token answered "request is
# not authorized" (dry-run). Catalog name: "Dynamic URL Redirects Write" (zone scope).
data "cloudflare_api_token_permission_groups_list" "dynamic_url_redirects_write" {
  name  = "Dynamic%20URL%20Redirects%20Write"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "tunnel_write" {
  name  = "Cloudflare%20Tunnel%20Write"
  scope = "com.cloudflare.api.account"
}

locals {
  zone_resource = { "com.cloudflare.api.account.zone.${var.zone_id}" = "*" }
  # tofu_apply edits every product zone (the cloudflare roots' applier — teststuff.net remote
  # access + the minutark bootstrap, oracle-iac#351). Same map as the ingress token.
  apply_zone_resources = { for name, id in var.ingress_zone_ids : "com.cloudflare.api.account.zone.${id}" => "*" }
  account_resource     = { "com.cloudflare.api.account.${var.account_id}" = "*" }
}

resource "cloudflare_api_token" "tofu_apply" {
  name = var.token_name

  # Zone-scoped: DNS records, client certs / mTLS hostname assoc, WAF custom rule.
  # ⚠ POLICY ORDER IS LOAD-BEARING: account-scoped policy FIRST (the API's return order) —
  # provider 5.19.1 compares policies positionally; zone-first = perpetual swap-diff + four
  # "inconsistent result" errors per apply (see observability-read.tf for the full record).
  policies = [
    # Account-scoped: the Cloudflare Tunnel + its remote config.
    {
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.tunnel_write.result[0].id },
      ]
      resources = jsonencode(local.account_resource)
    },
    {
      effect = "allow"
      # sort(): API returns permission_groups ascending by id (see observability-read.tf).
      permission_groups = [for gid in sort([
        data.cloudflare_api_token_permission_groups_list.dns_write.result[0].id,
        data.cloudflare_api_token_permission_groups_list.ssl_write.result[0].id,
        data.cloudflare_api_token_permission_groups_list.waf_write.result[0].id,
        data.cloudflare_api_token_permission_groups_list.zone_settings_write.result[0].id,
        data.cloudflare_api_token_permission_groups_list.dynamic_url_redirects_write.result[0].id,
      ]) : { id = gid }]
      resources = jsonencode(local.apply_zone_resources)
    },
  ]

  expires_on = var.expires_on

  condition = length(var.allowed_ips) > 0 ? {
    request_ip = { in = var.allowed_ips }
  } : null
}
