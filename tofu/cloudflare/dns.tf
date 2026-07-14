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

# WireGuard road-warrior endpoint (ADR-090) — the home WAN IP. DNS-only: Cloudflare
# can't proxy WireGuard UDP, and the whole point is a direct tunnel to OPNsense.
# The IP is a dynamic Telia lease: tofu owns the record's existence, NOT its content —
# ddclient on OPNsense keeps it fresh (ansible/opnsense-ddclient.yml, ADR-090).
resource "cloudflare_dns_record" "wg" {
  zone_id = var.zone_id
  name    = "wg"
  type    = "A"
  content = "176.46.101.184"
  proxied = false
  ttl     = 300
  comment = "WireGuard endpoint (home WAN, dynamic). Content owned by ddclient on OPNsense."
  lifecycle {
    ignore_changes = [content]
  }
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
