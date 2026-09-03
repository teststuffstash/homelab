# minutark.ee — the oracle-fleet product zone's bootstrap (oracle-iac#351, ADR-101 zone classes).
#
# The zone itself was created by hand (rare human-paced event, same posture as the registration:
# zone.ee registrar → NS benedict/paris → Active 2026-08-09). EVERYTHING IN the zone is declared
# here — the operator surveyed the dashboard and deliberately clicked nothing.
#
# Lives in this root (the teststuff.net remote-access root) as a pragmatic first home: the
# tofu_apply token now carries every product zone (var-driven map in tofu/cloudflare-token).
# When the PublicRoute composition grows its product-zone bootstrap class, this block migrates
# there — the resources are deliberately plain so a state move is cheap.
#
# NOT here, on purpose:
#   - the tunnel / any serving hostname — that is the first PublicRoute claim (oracle-iac),
#     placeholder-backend only until the gateway (T3c) exists;
#   - a Load Balancer — SPOF-ladder rung 2, priced only against the first SLA customer;
#   - CT-monitoring alerting — no clean provider v5 surface; the dashboard toggle is documented
#     in oracle-iac#351 and revisited when the provider grows one.

variable "minutark_zone_id" {
  type        = string
  description = "minutark.ee zone id (Cloudflare, created 2026-08-09)."
  default     = "fa1b02951c29ee4828b8948d0dd7baaf"
}

# ── records ─────────────────────────────────────────────────────────────────────────────────────
# The apex stays EMPTY until the PublicRoute claim brings the tunnel CNAME — an A record here
# would only resurrect the zone.ee parking page the import junk was deleted to kill.

resource "cloudflare_dns_record" "minutark_www" {
  zone_id = var.minutark_zone_id
  name    = "www"
  type    = "CNAME"
  content = "minutark.ee"
  proxied = true
  ttl     = 1 # auto (required by the API when proxied)
}

# No mail will EVER originate from this domain: hard-fail SPF + reject-all DMARC with strict
# alignment stops anyone spoofing @minutark.ee from the day the zone exists.
resource "cloudflare_dns_record" "minutark_spf" {
  zone_id = var.minutark_zone_id
  name    = "minutark.ee"
  type    = "TXT"
  content = "\"v=spf1 -all\""
  ttl     = 3600
}

resource "cloudflare_dns_record" "minutark_dmarc" {
  zone_id = var.minutark_zone_id
  name    = "_dmarc"
  type    = "TXT"
  content = "\"v=DMARC1; p=reject; sp=reject; adkim=s; aspf=s;\""
  ttl     = 3600
}

# ── redirects ───────────────────────────────────────────────────────────────────────────────────
# The www CNAME above sends www traffic INTO the apex claim's tunnel, but cloudflared routes by Host
# and the PublicRoute tunnel config lists only the claim hostname → www answered 404 (observed
# 2026-09-03; zone.ee's own URL-redirect feature is inert once the NS point at Cloudflare). The apex
# is canonical (claim hostname, cache rule, RUM all sit on it), so www redirects to it at the edge —
# a Single Redirect (Free plan; evaluated before the tunnel, so www never reaches the origin).
# `ref` keeps the rule id stable across updates (provider docs). Zone-bootstrap plumbing, not a
# route — it stays here beside the record it completes, not in the claim.
resource "cloudflare_ruleset" "minutark_redirects" {
  zone_id = var.minutark_zone_id
  name    = "minutark.ee redirects"
  kind    = "zone"
  phase   = "http_request_dynamic_redirect"
  rules = [{
    ref         = "www_to_apex"
    action      = "redirect"
    description = "www.minutark.ee → minutark.ee (apex canonical)"
    expression  = "(http.host eq \"www.minutark.ee\")"
    action_parameters = {
      from_value = {
        target_url = {
          expression = "concat(\"https://minutark.ee\", http.request.uri.path)"
        }
        status_code           = 301
        preserve_query_string = true
      }
    }
    enabled = true
  }]
}

# ── zone settings ───────────────────────────────────────────────────────────────────────────────
# TLS 1.2 floor blocks ~nobody (browsers dropped 1.0/1.1 in 2020; MCP clients are modern stacks;
# 1.2 is the compliance floor everywhere). API-first product ⇒ no plain-HTTP use case.

resource "cloudflare_zone_setting" "minutark_min_tls" {
  zone_id    = var.minutark_zone_id
  setting_id = "min_tls_version"
  value      = "1.2"
}

resource "cloudflare_zone_setting" "minutark_always_https" {
  zone_id    = var.minutark_zone_id
  setting_id = "always_use_https"
  value      = "on"
}

# ── DNSSEC ──────────────────────────────────────────────────────────────────────────────────────
# Cloudflare signs; the DS goes back to zone.ee BY HAND (registrar web flow — the doc rules out
# automating against zone.ee). The output below is the exact string to paste. Verify afterwards
# with an AUTHORITATIVE query (the 2026-08-09 lesson — recursive emptiness proves nothing):
#   devbox run -- dig DS minutark.ee @ns.tld.ee +norecurse   → must show this digest
resource "cloudflare_zone_dnssec" "minutark" {
  zone_id = var.minutark_zone_id
  status  = "active"
}

output "minutark_ds_record" {
  description = "DS record for the zone.ee registrar panel (add by hand, then authoritative-verify)."
  value = format(
    "%s %s %s %s",
    coalesce(cloudflare_zone_dnssec.minutark.key_tag, 0),
    coalesce(cloudflare_zone_dnssec.minutark.algorithm, ""),
    coalesce(cloudflare_zone_dnssec.minutark.digest_type, ""),
    coalesce(cloudflare_zone_dnssec.minutark.digest, ""),
  )
}
