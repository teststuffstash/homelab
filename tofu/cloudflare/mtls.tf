# --- Client certificate (mTLS) -------------------------------------------------------------
# Key + CSR generated here; Cloudflare's zone-managed CA signs it. The signed leaf + key get
# bundled into a .p12 for the phone (see outputs). Using the managed CA avoids the BYO-CA
# Enterprise gate; the leaf it signs sets cf.tls_client_auth.cert_verified at the edge.
resource "tls_private_key" "client" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "client" {
  private_key_pem = tls_private_key.client.private_key_pem

  subject {
    common_name = var.client_cert_common_name
  }
}

resource "cloudflare_client_certificate" "phone" {
  zone_id       = var.zone_id
  csr           = tls_cert_request.client.cert_request_pem
  validity_days = var.client_cert_validity_days
}

# Enable mTLS on the HA hostname. No mtls_certificate_id => associate with the active
# Cloudflare Managed CA, so certs it signed (above) verify. This is what makes the edge
# request + validate the client cert and populate cf.tls_client_auth.*.
resource "cloudflare_certificate_authorities_hostname_associations" "ha" {
  zone_id   = var.zone_id
  hostnames = [var.ha_hostname]
}

# --- Enforcement (WAF custom rule) ---------------------------------------------------------
# mTLS validation alone only *records* the result; this rule *enforces* it. Block any request
# to the HA host that didn't present a verified client cert. Scoped to the host so *.local and
# anything else are untouched.
resource "cloudflare_ruleset" "mtls_enforce" {
  zone_id     = var.zone_id
  name        = "mTLS enforcement"
  description = "Require a verified client certificate on the Home Assistant hostname"
  kind        = "zone"
  phase       = "http_request_firewall_custom"

  rules = [{
    ref         = "require_client_cert_ha"
    description = "Block ${var.ha_hostname} without a verified client cert"
    expression  = "(http.host eq \"${var.ha_hostname}\" and not cf.tls_client_auth.cert_verified)"
    action      = "block"
  }]
}
