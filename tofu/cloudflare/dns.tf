# v5 cloudflare_zero_trust_tunnel_cloudflared exposes no `.cname` — the tunnel's DNS
# target is <tunnel-id>.cfargotunnel.com. Proxied so the edge (mTLS + WAF) sits in front.
resource "cloudflare_dns_record" "ha" {
  zone_id = var.zone_id
  name    = "ha"
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.homelab.id}.cfargotunnel.com"
  proxied = true
  ttl     = 1 # automatic (required to be 1 when proxied)
}

# Work projects resolve *.local.teststuff.net -> 127.0.0.1 for local self-signed TLS envs.
# DNS-only (grey cloud): must NOT be proxied, and the edge mTLS/WAF must not touch it.
resource "cloudflare_dns_record" "wildcard_local" {
  zone_id = var.zone_id
  name    = "*.local"
  type    = "A"
  content = "127.0.0.1"
  proxied = false
  ttl     = 300
  comment = "Local self-signed TLS dev environments (work). DNS-only — do not proxy."
}
