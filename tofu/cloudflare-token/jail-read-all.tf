# homelab-jail-read-all — the IaC replacement for the dashboard-minted "Read all resources"
# token (applied + legacy deleted in the same operator sitting, 2026-08-12; the legacy expiry
# was 2026-12-13). Purpose unchanged from the legacy one: give jail sessions ONE read-everything
# credential for ad-hoc API archaeology — permission-group probes, token audits, settings dumps —
# where the curated observability token is deliberately narrower.
#
# THE GROUP SET IS FILTERED, NOT ENUMERATED (operator recommendation, 2026-08-12): the dashboard
# "read all" template is "every read group per scope" — 43 zone + 117 account + 2 user groups in
# the legacy dump (uploads/step3.json) — and hard-coding 162 ids would freeze the catalog at one
# day's state. Filtering the live catalog on the word "Read" reproduces the template's semantics
# AND picks up new groups on re-plan. `\bRead\b` rather than `Read$` because the dump has exactly
# one read group not ENDING in Read — "Magic Firewall Packet Captures - Read PCAPs API" — and a
# word-boundary match is still read-shaped by construction (no Cloudflare group grants write
# under a "Read" name; the day one does, the plan diff names it before anything applies).
data "cloudflare_api_token_permission_groups_list" "read_all_zone" {
  scope = "com.cloudflare.api.account.zone"
}

data "cloudflare_api_token_permission_groups_list" "read_all_user" {
  scope = "com.cloudflare.api.user"
}

locals {
  # account-scope catalog rides observability-read.tf's unfiltered `account_all` data source —
  # one catalog read per scope for the whole root. sort(): the API returns permission_groups
  # ascending by id and provider 5.x compares positionally (the observability token's lesson).
  jail_read_zone_ids = sort([
    for g in data.cloudflare_api_token_permission_groups_list.read_all_zone.result :
    g.id if can(regex("\\bRead\\b", g.name))
  ])
  jail_read_account_ids = sort([
    for g in data.cloudflare_api_token_permission_groups_list.account_all.result :
    g.id if can(regex("\\bRead\\b", g.name))
  ])
  jail_read_user_ids = sort([
    for g in data.cloudflare_api_token_permission_groups_list.read_all_user.result :
    g.id if can(regex("\\bRead\\b", g.name))
  ])
}

resource "cloudflare_api_token" "jail_read_all" {
  count = var.user_id == "" ? 0 : 1
  name  = "homelab-jail-read-all"

  # ⚠ POLICY ORDER: provider 5.x compares policies POSITIONALLY (the observability token's
  # account-first lesson). Minted 2026-08-12 in the legacy dump's order (zone, user, account);
  # the 2026-09-13 modify (the catalog grew "Zone Observability Read") ended in the usual two
  # "inconsistent result" errors and the API now reads back account, user, zone — mirrored here
  # (GET /user/tokens/<id>, the ingress-write.tf recipe: one re-plan, match the file to the
  # read-back order, never a second apply). The mutation itself lands either way (#5548/#5710).
  # ⚠ The GROUP order inside each policy is arbitrary on the API side for lists this size
  # (measured 2026-09-13: not catalog/id/name order) — expect a standing `~ id` permutation on
  # this token until the provider normalizes; docs/cloudflare.md gotcha 3 says how to read it.
  policies = [
    {
      # account.* like the legacy template (all accounts this user can see), not the single
      # account_resource — read-only, and the template's semantics are the contract here.
      effect            = "allow"
      permission_groups = [for gid in local.jail_read_account_ids : { id = gid }]
      resources         = jsonencode({ "com.cloudflare.api.account.*" = "*" })
    },
    {
      effect            = "allow"
      permission_groups = [for gid in local.jail_read_user_ids : { id = gid }]
      resources         = jsonencode({ "com.cloudflare.api.user.${var.user_id}" = "*" })
    },
    {
      effect            = "allow"
      permission_groups = [for gid in local.jail_read_zone_ids : { id = gid }]
      resources         = jsonencode({ "com.cloudflare.api.account.zone.*" = "*" })
    },
  ]

  # no expiry: read-only, and a silent expiry would strand jail sessions mid-probe with the same
  # dead-credential shape as FU-150; expiry VISIBILITY is the FU-156/FU-158 inventory belt's job.
}

output "jail_read_all_token" {
  description = "Read-everything jail credential (replaces the dashboard 'Read all resources' token — delete that after this applies). Store: KeePass (canonical) → ~/.claude/cloudflare/jail-read-all via wallet-files.sh."
  value       = var.user_id == "" ? "" : cloudflare_api_token.jail_read_all[0].value
  sensitive   = true
}
