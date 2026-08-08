# Token-inventory read (FU-156 credential-expiry belt): GET /user/tokens lists every token WITH
# expires_on — but the permission is USER-scoped (User: API Tokens: Read), which the
# account/zone-scoped observability token cannot carry. Gated on var.user_id so existing applies
# keep working until the operator supplies it (dashboard → My Profile, or
# `curl -H "Authorization: Bearer <admin>" https://api.cloudflare.com/client/v4/user | jq .result.id`).
data "cloudflare_api_token_permission_groups_list" "api_tokens_read" {
  count = var.user_id == "" ? 0 : 1
  name  = "API%20Tokens%20Read"
  scope = "com.cloudflare.api.user"
}

resource "cloudflare_api_token" "inventory_read" {
  count = var.user_id == "" ? 0 : 1
  name  = "homelab-token-inventory-read"

  policies = [{
    effect = "allow"
    permission_groups = [
      { id = data.cloudflare_api_token_permission_groups_list.api_tokens_read[0].result[0].id },
    ]
    resources = jsonencode({ "com.cloudflare.api.user.${var.user_id}" = "*" })
  }]
  # no expiry — this token EXISTS to watch expiries (FU-150: the watcher must not go dark)
}

output "inventory_read_token" {
  description = "Expiry-belt credential (empty until var.user_id is set). Store: wallet cloudflare-inventory-read + Infisical CLOUDFLARE_INVENTORY_READ."
  value       = var.user_id == "" ? "" : cloudflare_api_token.inventory_read[0].value
  sensitive   = true
}
