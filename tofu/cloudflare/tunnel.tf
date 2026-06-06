# Remotely-managed Cloudflare Tunnel (config_src = cloudflare): cloudflared just needs the
# token, no local config file. We push the ingress config via the _config resource below.
resource "cloudflare_zero_trust_tunnel_cloudflared" "homelab" {
  account_id = var.account_id
  name       = "homelab"
  config_src = "cloudflare"
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "homelab" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

# Ingress: ha.teststuff.net -> in-cluster HA; everything else -> 404 (required catch-all).
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "homelab" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
  source     = "cloudflare"

  config = {
    ingress = [
      {
        hostname = var.ha_hostname
        service  = var.ha_service
      },
      {
        service = "http_status:404"
      },
    ]
  }
}
