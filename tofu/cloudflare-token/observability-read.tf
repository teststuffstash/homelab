# Read-only observability token (operator direction 2026-08-08: "give the jail LLMs read access
# to Cloudflare or I keep clicking through UIs looking for logs/errors"). ONE token, three
# consumers, zero write paths:
#   1. the jail LLM sessions — ad-hoc GraphQL analytics / security-event / tunnel-status queries
#      (file cache at ~/.claude/cloudflare/observability-read via the wallet);
#   2. the in-cluster Cloudflare Prometheus exporter (Infisical → ESO);
#   3. later, the responder's triage sessions (same ESO path, read = safe to hand around).
# Scope is ALL zones + account-level reads on purpose: future product zones (FU-039 public
# ingress) should be visible to observability the day they exist, without a re-mint.
# Free-plan honesty: per-request logs (Logpull/Logpush) are Enterprise — deliberately NOT
# requested; GraphQL aggregated analytics + security events are what the plan actually serves.

data "cloudflare_api_token_permission_groups_list" "analytics_read_zone" {
  name  = "Analytics%20Read"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "analytics_read_account" {
  name  = "Account%20Analytics%20Read"
  scope = "com.cloudflare.api.account"
}

data "cloudflare_api_token_permission_groups_list" "waf_read" {
  name  = "Zone%20WAF%20Read"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "tunnel_read" {
  name  = "Cloudflare%20Tunnel%20Read"
  scope = "com.cloudflare.api.account"
}

# Audit-logs read: the exact catalog name drifted from every guess ("Audit Logs Read" → empty
# list, live 2026-08-08), so select by regex over the unfiltered account-scope catalog instead.
# `one()` keeps it FAIL-LOUD: zero or multiple matches abort the plan with a clear error.
data "cloudflare_api_token_permission_groups_list" "account_all" {
  scope = "com.cloudflare.api.account"
}

locals {
  audit_logs_read_id = one([
    for g in data.cloudflare_api_token_permission_groups_list.account_all.result :
    g.id if can(regex("(?i)audit log", g.name)) && can(regex("(?i)read", g.name))
  ])
}

resource "cloudflare_api_token" "observability_read" {
  name = "homelab-observability-read"

  policies = [
    {
      # every zone in the account, read-only — includes zones created later
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.analytics_read_zone.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.zone_read.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.waf_read.result[0].id },
      ]
      resources = jsonencode({ "com.cloudflare.api.account.zone.*" = "*" })
    },
    {
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.analytics_read_account.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.tunnel_read.result[0].id },
        { id = local.audit_logs_read_id },
      ]
      resources = jsonencode(local.account_resource)
    },
  ]

  # no expiry: read-only, and a silent expiry would blind the exporter (the FU-150 lesson —
  # a dead observability credential looks exactly like a quiet edge)
}

output "observability_read_token" {
  description = "Read-only token for jail LLMs + the CF Prometheus exporter + responder triage. Store: KeePass (canonical) → ~/.claude/cloudflare/observability-read (jail) + Infisical CLOUDFLARE_OBSERVABILITY_READ (cluster)."
  value       = cloudflare_api_token.observability_read.value
  sensitive   = true
}
