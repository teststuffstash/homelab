# Scoped write token for the PublicRoute composition (FU-039 public ingress, ADR-101) — the
# in-cluster provider-terraform credential. v1 (2026-08-08) = the ROUTES leg only: DNS Write +
# Tunnel Write. v2 (2026-09-03, G-G goal #1302) adds the PROFILE legs the composition now renders
# per claim — zone-phase rulesets (cache / rate-limit / managed-skip / CORS) — because the first
# live consumer-profile apply died at Cloudflare with "Authentication error" while the cf-api-proxy
# allowlist (the OTHER layer) had already been widened. SSL stays out (no profile renders it).
# ⚖ RUM (`cloudflare_web_analytics_site`/`_rule`, account-scoped /rum/site_info): NO write
# permission group named Web Analytics/RUM exists in the 395-group list (2026-09-03 read) — the
# operator's apply + a re-run of the Workspace tells whether Account-scoped rulesets/settings
# cover it; until then the consumer profile's RUM half may still 403 (record the outcome here).
# Storing this token in Infisical as CLOUDFLARE_INGRESS_WRITE is the ARMING act for the whole
# capability (the crossplane ExternalSecret stays NotReady until then).
locals {
  # name => id map flattened to the API's per-zone resource keys; one entry per product zone.
  ingress_zone_resources = { for name, id in var.ingress_zone_ids : "com.cloudflare.api.account.zone.${id}" => "*" }
}

resource "cloudflare_api_token" "ingress_write" {
  name = "homelab-ingress-write"

  # ⚠ POLICY ORDER IS LOAD-BEARING: account-scoped policy FIRST (the API's return order) —
  # provider 5.19.1 compares policies positionally; zone-first = perpetual swap-diff + four
  # "inconsistent result" errors per apply (see observability-read.tf for the full record).
  policies = [
    {
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.tunnel_write.result[0].id },
      ]
      resources = jsonencode(local.account_resource)
    },
    {
      effect = "allow"
      # sort(): the API returns permission_groups ascending by id (see observability-read.tf).
      permission_groups = [for gid in sort([
        data.cloudflare_api_token_permission_groups_list.dns_write.result[0].id,
        data.cloudflare_api_token_permission_groups_list.cache_settings_write.result[0].id,
        data.cloudflare_api_token_permission_groups_list.waf_write.result[0].id,
        data.cloudflare_api_token_permission_groups_list.zone_transform_rules_write.result[0].id,
      ]) : { id = gid }]
      resources = jsonencode(local.ingress_zone_resources)
    },
  ]

  expires_on = var.expires_on # renewal rides the FU-156 belt + the store script
}

output "ingress_write_token" {
  description = "PublicRoute composition credential. Store: wallet cloudflare-ingress-write + Infisical CLOUDFLARE_INGRESS_WRITE (the arming act)."
  value       = cloudflare_api_token.ingress_write.value
  sensitive   = true
}
