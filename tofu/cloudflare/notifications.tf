# The OUTSIDE-vantage check on the public path (oracle handoff 2026-11-21): Cloudflare's own
# Tunnel Health Alert, delivered by Cloudflare — so it does not depend on our WAN, DNS or
# Alertmanager, unlike the in-cluster CloudflaredTunnelDown (which only RECORDS an outage,
# arriving late over the same link). Account-wide, no filters: every tunnel (every PublicRoute
# claim's, both zones) and every status change (Healthy/Degraded/Down/Inactive). Standalone
# Health Checks were the other candidate and are not entitled on the free plan (entitlement
# health_checks.enabled=false, read 2026-11-22). docs/cloudflare.md §Observability.
#
# Destination: the email address the account's existing Passive Origin Monitoring policy already
# delivers to (the account's one destination; no webhook destinations exist) — read, not written,
# so the address never enters this public repo.
data "cloudflare_notification_policies" "all" {
  account_id = var.account_id
}

locals {
  notification_emails = distinct(flatten([
    for p in data.cloudflare_notification_policies.all.result :
    [for m in coalesce(try(p.mechanisms.email, null), []) : m.id]
    if p.alert_type == "real_origin_monitoring"
  ]))
}

resource "cloudflare_notification_policy" "tunnel_health" {
  account_id  = var.account_id
  name        = "Tunnel health (every PublicRoute tunnel)"
  description = "A Cloudflare Tunnel changed health status. Seen from Cloudflare's edge, so it arrives during a homelab WAN loss. Managed in homelab tofu/cloudflare/notifications.tf."
  alert_type  = "tunnel_health_event"
  enabled     = true

  mechanisms = {
    email = [for e in local.notification_emails : { id = e }]
  }

  lifecycle {
    precondition {
      condition     = length(local.notification_emails) > 0
      error_message = "No email destination found on the account's real_origin_monitoring policy — the tunnel health alert would deliver nowhere."
    }
  }
}
