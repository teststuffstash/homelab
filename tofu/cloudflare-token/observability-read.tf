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

# Zone Settings Read (added 2026-08-09): the #351 acceptance verifies zone settings (min TLS,
# always-HTTPS) via the API, and the meta jail's settings probes 403'd without it — Zone Read
# covers metadata, not the settings panel. Read-only, all zones, same posture as the rest.
data "cloudflare_api_token_permission_groups_list" "zone_settings_read" {
  name  = "Zone%20Settings%20Read"
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "tunnel_read" {
  name  = "Cloudflare%20Tunnel%20Read"
  scope = "com.cloudflare.api.account"
}

# Audit-logs read, take 3 — and the lesson is "ask the ENDPOINT, not the catalog". Take 1
# exact-matched "Audit Logs Read": no such group exists at account scope, empty list. Take 2
# regexed "(?i)audit log" over the catalog and silently matched "Access: Audit Logs Read" —
# the Zero Trust Access product's group, useless here — and the minted token 403'd on both
# audit-log endpoints (found live 2026-08-08 when the meta session probed them). The
# authoritative answer is in the endpoint's own docs
# (developers.cloudflare.com/fundamentals/account/account-security/audit-logs/): the
# accounts/{id}/logs/audit API requires **Account Settings Read** (or Write). So: exact name,
# the one the docs demand, `one()` still fail-loud if Cloudflare ever renames it. Slightly
# broader than audit logs alone (it reads account settings generally) — read-only, accepted
# for the observability token.
data "cloudflare_api_token_permission_groups_list" "account_all" {
  scope = "com.cloudflare.api.account"
}

locals {
  audit_logs_read_id = one([
    for g in data.cloudflare_api_token_permission_groups_list.account_all.result :
    g.id if g.name == "Account Settings Read"
  ])
}

resource "cloudflare_api_token" "observability_read" {
  name = "homelab-observability-read"

  # ⚠ POLICY ORDER IS LOAD-BEARING (2026-08-09): the API returns multi-policy tokens with the
  # ACCOUNT-scoped policy first and the zone-scoped one second, and provider 5.19.1 still compares
  # policies POSITIONALLY (the 5.13.0 order fix covered account_token, not this shape) — with the
  # zone policy listed first, EVERY plan shows the two policies swapping and every apply ends in
  # four "Provider produced inconsistent result" errors while succeeding on the wire (verified:
  # the mutation lands; /zones through the token confirms). Keep account-first and the plan stays
  # empty. Upstream refs: cloudflare/terraform-provider-cloudflare#5548, #5710, fix PR#6440.
  policies = [
    {
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.analytics_read_account.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.tunnel_read.result[0].id },
        { id = local.audit_logs_read_id },
      ]
      resources = jsonencode(local.account_resource)
    },
    {
      # every zone in the account, read-only — includes zones created later
      effect = "allow"
      permission_groups = [
        { id = data.cloudflare_api_token_permission_groups_list.analytics_read_zone.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.zone_read.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.waf_read.result[0].id },
        { id = data.cloudflare_api_token_permission_groups_list.zone_settings_read.result[0].id },
      ]
      resources = jsonencode({ "com.cloudflare.api.account.zone.*" = "*" })
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
