# Dedicated least-privilege token for OPNsense ACME DNS-01 (acme.sh dns_cf): create the
# _acme-challenge TXT records on teststuff.net. Separate from homelab-tofu-apply — it lives in
# a different trust domain (the router), so it gets only what acme.sh needs: DNS Write + Zone
# Read, scoped to the one zone. Minted here, entered into OPNsense via env (never committed).

data "cloudflare_api_token_permission_groups_list" "zone_read" {
  name  = "Zone%20Read"
  scope = "com.cloudflare.api.account.zone"
}

resource "cloudflare_api_token" "acme_dns" {
  name = "homelab-acme-dns"

  policies = [{
    effect = "allow"
    permission_groups = [
      { id = data.cloudflare_api_token_permission_groups_list.dns_write.result[0].id },
      { id = data.cloudflare_api_token_permission_groups_list.zone_read.result[0].id },
    ]
    resources = jsonencode(local.zone_resource)
  }]

  expires_on = var.expires_on

  condition = length(var.allowed_ips) > 0 ? {
    request_ip = { in = var.allowed_ips }
  } : null
}

output "acme_dns_token" {
  description = "Cloudflare token for OPNsense ACME DNS-01. Save: tofu -chdir=tofu/cloudflare-token output -raw acme_dns_token"
  value       = cloudflare_api_token.acme_dns.value
  sensitive   = true
}
