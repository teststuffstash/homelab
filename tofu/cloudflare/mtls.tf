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

# --- Enforcement (WAF custom rule) — NOT here since 2026-10-26 --------------------------------
# The block rule (`not cf.tls_client_auth.cert_verified` on the HA host) is rendered by the ha
# PublicRoute claim (.spec.mtls.enforce) into the zone's http_request_firewall_custom ruleset,
# which the claim ADOPTED from this root (removed.tf). What stays here is the CREDENTIAL half the
# composition's token cannot write (SSL/Certificates): the client cert and the hostname association
# above — without the association the edge never asks for a certificate and the claim's rule
# blocks every request.
