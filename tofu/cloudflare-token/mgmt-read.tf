# homelab-mgmt-read — the management box's READ-ONLY twin of the `homelab-tofu-apply` write token
# (FU-238, ADR-131): what lets the box `tofu plan` the tofu/cloudflare root on every PR head
# (the sentinel's stage 2) while the WRITE key it held as a phase-A shortcut retires from
# `/var/lib/mgmt/env`. Applies of that root stay in the jail with the write key, plan-gated.
#
# The group set is the write token's, group for group, in its Read form — nothing more, and the
# box's first plan is the proof (measured from the jail 2026-09-13 with the read-all token:
# every state resource refreshes; with the observability token the DNS records + DNSSEC 401
# without `DNS Read`, the redirect ruleset without `Dynamic URL Redirects Read`, the mTLS pair
# without `SSL and Certificates Read`). The ONE thing no read group covers is the tunnel TOKEN
# data source (`GET …/cfd_tunnel/<id>/token` is a credential read — 401 under every Read group,
# the read-all token included), so the policy excludes it on the box (`plan_exclude_types`,
# policy/mgmt/plan-input.yaml) and the cloudflared Secret + Deployment fall out with it as its
# dependents; the verdict names all three as "not planned". Same zone set as the write token
# (local.apply_zone_resources — both product zones), same expiry (rotated together, FU-156).

data "cloudflare_api_token_permission_groups_list" "dns_read" {
  name  = "DNS%20Read"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "ssl_read" {
  name  = "SSL%20and%20Certificates%20Read"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "dynamic_url_redirects_read" {
  name  = "Dynamic%20URL%20Redirects%20Read"
  scope = "com.cloudflare.api.account.zone"
}

resource "cloudflare_api_token" "mgmt_read" {
  name = "homelab-mgmt-read"

  # ⚠ POLICY ORDER IS LOAD-BEARING: account-scoped policy FIRST (main.tf's lesson — provider 5.x
  # compares positionally); sort(): the API returns permission_groups ascending by id.
  policies = [
    {
      # account: the tunnel + its remote config (refresh only)
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.tunnel_read.result[0].id },
      ]
      resources = jsonencode(local.account_resource)
    },
    {
      # zone: DNS records + DNSSEC, the mTLS client cert + CA hostname association, the WAF
      # custom-rules ruleset, the two zone settings, the www→apex redirect ruleset
      effect = "allow"
      permission_groups = [for gid in sort([
        data.cloudflare_api_token_permission_groups_list.dns_read.result[0].id,
        data.cloudflare_api_token_permission_groups_list.ssl_read.result[0].id,
        data.cloudflare_api_token_permission_groups_list.waf_read.result[0].id,
        data.cloudflare_api_token_permission_groups_list.zone_settings_read.result[0].id,
        data.cloudflare_api_token_permission_groups_list.dynamic_url_redirects_read.result[0].id,
      ]) : { id = gid }]
      resources = jsonencode(local.apply_zone_resources)
    },
  ]

  expires_on = var.expires_on
}

output "mgmt_read_token" {
  description = "The management box's read-only tofu/cloudflare credential. Store: wallet cloudflare-mgmt-read (scripts/cloudflare-token-store.sh), then scripts/mgmt-provision-secrets.sh --push ships it as CLOUDFLARE_API_TOKEN."
  value       = cloudflare_api_token.mgmt_read.value
  sensitive   = true
}
