#!/usr/bin/env bash
# Package the Cloudflare-signed client leaf + its key into a PKCS#12 for the phone
# (Home Assistant mTLS — see tofu/cloudflare/, docs/cloudflare.md).
#
# Reproducible on purpose:
#   - The key + CSR come from the PINNED hashicorp/tls provider; the leaf is signed by
#     Cloudflare's managed CA. openssl never generates the certificate.
#   - openssl is PINNED via devbox (3.6.0) and only wraps the PKCS#12, with EXPLICIT
#     algorithms — never the openssl *defaults*, which drift across versions and have
#     silently broken mTLS imports (OpenSSL 1.x RC2/3DES -> 3.x AES, MAC alg changes).
#   - Non-interactive: the export password is read from a file, never prompted.
#
# Run it directly (NOT via `devbox run` — it calls the pinned binaries by absolute path):
#   bash scripts/make-client-p12.sh
#
# Outputs into the jail-private, gitignored ~/.claude/cloudflare/ (override: HOMELAB_CF_DIR):
#   ha-client.p12              install on the phone
#   ha-client.p12.password     import password (generated once if absent)
#   ha-client.cert.pem/.der/.txt   the leaf, for verification + diffing
#
# NB: a .p12 is NOT byte-reproducible (random salt/IV each run) — so don't diff the
# container. Diff the CERTIFICATE: load ha-client.cert.der into https://lapo.it/asn1js
# (two tabs to compare). The .der is the deterministic artifact.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OPENSSL="$REPO/.devbox/nix/profile/default/bin/openssl"
TOFU="$REPO/.devbox/nix/profile/default/bin/tofu"
[ -x "$OPENSSL" ] || { echo "pinned openssl missing ($OPENSSL) — run: devbox install" >&2; exit 1; }
[ -x "$TOFU" ]    || { echo "pinned tofu missing ($TOFU) — run: devbox install" >&2; exit 1; }

DEST="${HOMELAB_CF_DIR:-$HOME/.claude/cloudflare}"
umask 077
mkdir -p "$DEST"; chmod 700 "$DEST"

# Record exactly which openssl wrapped this bundle.
echo "openssl: $("$OPENSSL" version)"

# 1. Export password (non-interactive): reuse if present, else generate once.
PWFILE="$DEST/ha-client.p12.password"
[ -s "$PWFILE" ] || "$OPENSSL" rand -base64 18 > "$PWFILE"
chmod 600 "$PWFILE"

# 2. Pull the leaf + key from tofu state (sensitive outputs; reads state, no API calls).
CRT="$(mktemp)"; KEY="$(mktemp)"; trap 'rm -f "$CRT" "$KEY"' EXIT
"$TOFU" -chdir="$REPO/tofu/cloudflare" output -raw client_cert_pem > "$CRT"
"$TOFU" -chdir="$REPO/tofu/cloudflare" output -raw client_key_pem  > "$KEY"

# 3. Wrap into PKCS#12 with EXPLICIT, modern algorithms (no version-default surprises).
"$OPENSSL" pkcs12 -export \
  -inkey "$KEY" -in "$CRT" \
  -name "Home Assistant mTLS" \
  -certpbe aes-256-cbc -keypbe aes-256-cbc -macalg sha256 -iter 2048 \
  -passout "file:$PWFILE" \
  -out "$DEST/ha-client.p12"

# 4. Emit the leaf for verification / asn1js diffing.
cp "$CRT" "$DEST/ha-client.cert.pem"
"$OPENSSL" x509 -in "$CRT" -outform der -out "$DEST/ha-client.cert.der"
"$OPENSSL" x509 -in "$CRT" -noout -text > "$DEST/ha-client.cert.txt"
chmod 600 "$DEST"/ha-client.*

echo "wrote $DEST/ha-client.p12  (+ .password, .cert.pem/.der/.txt)"
echo "diff the cert on https://lapo.it/asn1js -> $DEST/ha-client.cert.der"
