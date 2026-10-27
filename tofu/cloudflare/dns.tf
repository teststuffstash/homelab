# The `ha` CNAME moved to the ha PublicRoute claim on 2026-10-26 (argocd/resources/ha-publicroute/,
# FU-039 consumer #2) — ADOPTED by the claim's Workspace (an import block), so this root FORGETS
# it rather than destroying it (removed.tf).

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

# Proton Mail custom-domain ownership proof (2026-10-27): teststuff.net becomes the ONE mail
# domain (a Proton mailbox); every other domain forwards into it via Cloudflare Email Routing.
# Proton re-checks this record to confirm continued ownership — never remove it while the domain
# is on Proton. Not a secret (public DNS by design). MX/SPF/DKIM/DMARC follow once verified.
resource "cloudflare_dns_record" "proton_verification" {
  zone_id = var.zone_id
  name    = "teststuff.net"
  type    = "TXT"
  content = "\"protonmail-verification=89dbb6fc6fd41e4229d0271c3b6bfee27749166d\""
  ttl     = 3600
  comment = "Proton Mail domain verification — keep while teststuff.net mail is on Proton."
}

# Proton Mail for teststuff.net — the records Proton's domain wizard issued (2026-10-27), verbatim.
# All DNS-only: mail records are never proxied.
resource "cloudflare_dns_record" "proton_mx" {
  for_each = { "mail.protonmail.ch" = 10, "mailsec.protonmail.ch" = 20 }
  zone_id  = var.zone_id
  name     = "teststuff.net"
  type     = "MX"
  content  = each.key
  priority = each.value
  ttl      = 3600
  comment  = "Proton Mail inbound (teststuff.net is the company's mail domain)."
}

# Proton's suggested soft-fail (~all), not minutark's -all: this domain DOES send, through Proton.
resource "cloudflare_dns_record" "proton_spf" {
  zone_id = var.zone_id
  name    = "teststuff.net"
  type    = "TXT"
  content = "\"v=spf1 include:_spf.protonmail.ch ~all\""
  ttl     = 3600
  comment = "SPF: only Proton sends as teststuff.net."
}

# DKIM: Proton rotates keys behind these CNAMEs — the targets are per-domain and stable.
resource "cloudflare_dns_record" "proton_dkim" {
  for_each = toset(["protonmail", "protonmail2", "protonmail3"])
  zone_id  = var.zone_id
  name     = "${each.key}._domainkey"
  type     = "CNAME"
  content  = "${each.key}.domainkey.ds2ossz6ahlcifdibluvfm5ittjl5vizkbfiwwo2qguhnkui65kpq.domains.proton.ch"
  proxied  = false
  ttl      = 3600
  comment  = "Proton Mail DKIM (Proton-managed key rotation)."
}

# Proton's suggested starting policy + aggregate reports to dmarc@ (a Proton address, 2026-10-27);
# tighten to p=reject once the reports show only Proton sending as teststuff.net.
resource "cloudflare_dns_record" "proton_dmarc" {
  zone_id = var.zone_id
  name    = "_dmarc"
  type    = "TXT"
  content = "\"v=DMARC1; p=quarantine; rua=mailto:dmarc@teststuff.net\""
  ttl     = 3600
  comment = "DMARC for the mail domain (Proton)."
}
