output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.homelab.id
}

output "ha_url" {
  value = "https://${var.ha_hostname}"
}

output "client_cert_pem" {
  description = "Signed client leaf (PEM). For the phone .p12 — see make_p12_command."
  value       = cloudflare_client_certificate.phone.certificate
  sensitive   = true
}

output "client_key_pem" {
  description = "Client private key (PEM). Keep secret; only needed to build the .p12."
  value       = tls_private_key.client.private_key_pem
  sensitive   = true
}

# Build the phone's PKCS#12 with the PINNED devbox openssl + EXPLICIT algorithms (never
# openssl defaults — they drift across versions and break mTLS imports). The script reads
# these sensitive outputs from state; don't hand-roll openssl here.
output "make_p12_command" {
  value = "bash scripts/make-client-p12.sh   # -> ~/.claude/cloudflare/ha-client.p12 (+ .password, .cert.der for asn1js)"
}
