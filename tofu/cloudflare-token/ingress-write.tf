# Scoped write token for the PublicRoute composition (FU-039 public ingress, ADR-101) — the
# in-cluster provider-terraform credential. v1 scope = the ROUTES leg only: DNS Write on the
# PLATFORM zone + Tunnel Write on the account. Deliberately NOT WAF/SSL — the zone-phase
# rulesets (cache, api-no-challenge) are the open aggregation leg and get their own decision.
# Storing this token in Infisical as CLOUDFLARE_INGRESS_WRITE is the ARMING act for the whole
# capability (the crossplane ExternalSecret stays NotReady until then).
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
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.dns_write.result[0].id },
      ]
      resources = jsonencode(local.zone_resource)
    },
  ]

  expires_on = var.expires_on # renewal rides the FU-156 belt + the store script
}

output "ingress_write_token" {
  description = "PublicRoute composition credential. Store: wallet cloudflare-ingress-write + Infisical CLOUDFLARE_INGRESS_WRITE (the arming act)."
  value       = cloudflare_api_token.ingress_write.value
  sensitive   = true
}
