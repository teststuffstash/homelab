#!/usr/bin/env bash
# Create / seed the homelab bootstrap KeePass wallet (one-time, idempotent).
#
# This is the Tier-0 "outer ring" secret store (see docs/secrets.md): the handful of
# credentials that must exist BEFORE the cluster can decrypt anything for itself —
# Infisical's own keys, the ArgoCD git credential, etc. Everything downstream of
# Infisical+ESO does NOT belong here.
#
# The wallet is key-file-only (no master password) so the jail can read it
# unattended; both files live under ~/.claude (the jail's existing secret boundary,
# gitignored by being out of the repo). Copy homelab.kdbx + homelab.keyx to your
# laptop to open it in the KeePassXC GUI.
#
#   bash scripts/keepass-init.sh          # create wallet + seed (prompts only for missing values)
#
# Re-running only adds entries that are missing; existing values are left untouched.
set -euo pipefail

KP_DIR="${KP_DIR:-$HOME/.claude/homelab-keepass}"
DB="$KP_DIR/homelab.kdbx"
KEY="$KP_DIR/homelab.keyx"
export DEVBOX_QUIET=1
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

# keepassxc-cli, directly if on PATH else via devbox
if command -v keepassxc-cli >/dev/null 2>&1; then
  kp() { keepassxc-cli "$@"; }
else
  kp() { devbox run --quiet -- keepassxc-cli "$@"; }
fi

mkdir -p "$KP_DIR"; chmod 700 "$KP_DIR"

if [ ! -f "$DB" ]; then
  echo "Creating wallet $DB (key-file-only)"
  kp db-create -q --set-key-file "$KEY" "$DB"
  chmod 600 "$DB" "$KEY"
else
  echo "Wallet already exists: $DB"
fi

has_entry() { kp show -q --no-password -k "$KEY" "$DB" "$1" >/dev/null 2>&1; }

# add_secret <title> <value>     — add only if the entry is missing
add_secret() {
  local title="$1" value="$2"
  if has_entry "$title"; then
    echo "  = $title (exists, kept)"
  else
    printf '%s\n' "$value" | kp add -q --no-password -k "$KEY" --password-prompt "$DB" "$title" >/dev/null
    echo "  + $title"
  fi
}

gen_hex()    { openssl rand -hex "${1:-16}"; }
gen_b64()    { openssl rand -base64 "${1:-32}"; }
# strong password that satisfies Infisical's policy (len + upper/lower/digit/special)
gen_admin_pw() { printf '%sAa1!' "$(openssl rand -base64 21 | tr -d '/+=')"; }
file_or()    { [ -f "$1" ] && tr -d '\n' <"$1" || echo "$2"; }

echo "Seeding entries:"
# --- Infisical bootstrap (the keys ESO can't bootstrap; see tofu/argocd.tf) ---
add_secret infisical-encryption-key "$(gen_hex 16)"     # ENCRYPTION_KEY (32 hex chars)
add_secret infisical-auth-secret    "$(gen_b64 32)"     # AUTH_SECRET
add_secret infisical-db-password     "$(gen_b64 24 | tr -d '/+=')"  # CNPG app-role pw (URL-safe)
# Infisical super admin — created declaratively by the chart's autoBootstrap job.
add_secret infisical-admin-email    "admin@teststuff.net"
add_secret infisical-admin-password "$(gen_admin_pw)"

# --- ArgoCD git credential (repo is private → ArgoCD needs read access) --------
# Reuse the existing fine-grained PAT from the git remote if present, else placeholder.
gh_pat="$(git -C "$(dirname "$0")/.." remote get-url origin 2>/dev/null | sed -n 's#.*x-access-token:\([^@]*\)@.*#\1#p')"
add_secret argocd-github-pat "${gh_pat:-REPLACE_with_github_pat}"

# --- migrate existing plaintext cred files into the wallet ---------------------
# (FU-001: the wallet is the authoritative Tier-0 store as of 2026-07-12; the ~/.claude flat
# files are a legacy READ path that shrinks as each consumer converts — checklist in FU-001.
# add_secret only adds MISSING entries, so re-running never clobbers a rotated wallet value.)
add_secret grafana-admin-password "$(file_or "$HOME/.claude/homelab-ha/grafana_admin_password" REPLACE)"
add_secret ha-prometheus-token    "$(file_or "$HOME/.claude/homelab-ha/prometheus_llat" REPLACE)"
add_secret forgejo-runner-token   "$(file_or "$HOME/.claude/homelab-forgejo/runner-token" REPLACE)"

add_secret opnsense-api-key     "$(file_or "$HOME/.claude/homelab-opnsense/key" REPLACE)"
add_secret opnsense-api-secret  "$(file_or "$HOME/.claude/homelab-opnsense/secret" REPLACE)"
add_secret pve-api-token-matchbox "$(file_or "$HOME/.claude/homelab-pve-ssh/api_token_matchbox" REPLACE)"
add_secret pve-api-token-tofu    "$(file_or "$HOME/.claude/homelab-pve-ssh/api_token_tofu" REPLACE)"  # main root (FU-004); recovery copy of terraform.tfvars value
add_secret ha-access-token      "$(file_or "$HOME/.claude/homelab-ha/access_token" REPLACE)"  # long-lived token (FU-003)
add_secret ha-owner-password    "$(file_or "$HOME/.claude/homelab-ha/owner_password" REPLACE)"
add_secret droplet-api-encryption-key "$(file_or "$HOME/.claude/homelab-droplet/api_encryption_key" REPLACE)"
add_secret droplet-ota-password "$(file_or "$HOME/.claude/homelab-droplet/ota_password" REPLACE)"
add_secret aws-audit-key-id     "$(file_or "$HOME/.claude/homelab-aws/audit-key" REPLACE)"
add_secret aws-audit-secret     "$(file_or "$HOME/.claude/homelab-aws/audit-secret" REPLACE)"
add_secret cloudflare-acme-token "$(file_or "$HOME/.claude/cloudflare/acme-token" REPLACE)"
add_secret cloudflare-read-key   "$(file_or "$HOME/.claude/cloudflare/read-key" REPLACE)"
add_secret cloudflare-write-key  "$(file_or "$HOME/.claude/cloudflare/write-key" REPLACE)"
add_secret cloudflare-ha-client-p12-password "$(file_or "$HOME/.claude/cloudflare/ha-client.p12.password" REPLACE)"
add_secret forgejo-api-token     "$(file_or "$HOME/.claude/homelab-forgejo/api-token" REPLACE)"
add_secret forgejo-rasmus-password "$(file_or "$HOME/.claude/homelab-forgejo/rasmus-password" REPLACE)"
add_secret forgejo-gpg-keyid     "$(file_or "$HOME/.claude/homelab-forgejo/gpg-keyid" REPLACE)"
add_secret garage-admin-token    "$(file_or "$HOME/.claude/homelab-garage/admin-token" REPLACE)"
add_secret garage-browse-key-id  "$(file_or "$HOME/.claude/homelab-garage/browse-key-id" REPLACE)"
add_secret garage-browse-secret  "$(file_or "$HOME/.claude/homelab-garage/browse-secret" REPLACE)"
add_secret github-reviewer-app-id "$(file_or "$HOME/.claude/homelab-github-reviewer/app-id" REPLACE)"
add_secret github-reviewer-installation-id "$(file_or "$HOME/.claude/homelab-github-reviewer/installation-id" REPLACE)"
add_secret github-reviewer-slug  "$(file_or "$HOME/.claude/homelab-github-reviewer/slug" REPLACE)"
add_secret snore-recorder-key    "$(file_or "$HOME/.claude/homelab-snore-recorder/key.txt" REPLACE)"
# (homelab-ha/{auth_code,esphome_flow_id} are expired one-time OAuth/flow artifacts — not migrated.)

# add_attachment <entry> <name> <file> — multi-line material (keys/certs/p12) rides as an
# attachment on its entry (created empty if missing). Import only when absent, like add_secret.
add_attachment() {
  local title="$1" name="$2" file="$3"
  [ -f "$file" ] || { echo "  ! $title/$name (source $file missing, skipped)"; return 0; }
  has_entry "$title" || printf '\n' | kp add -q --no-password -k "$KEY" --password-prompt "$DB" "$title" >/dev/null
  if kp attachment-export -q --no-password -k "$KEY" --stdout "$DB" "$title" "$name" >/dev/null 2>&1; then
    echo "  = $title/$name (exists, kept)"
  else
    kp attachment-import -q --no-password -k "$KEY" "$DB" "$title" "$name" "$file" >/dev/null
    echo "  + $title/$name"
  fi
}

add_attachment pve-ssh-seed        id_ed25519     "$HOME/.claude/homelab-pve-ssh/id_ed25519"
add_attachment pve-ssh-seed        id_ed25519.pub "$HOME/.claude/homelab-pve-ssh/id_ed25519.pub"
add_attachment matchbox-grpc       ca.crt         "$HOME/.claude/homelab-matchbox/ca.crt"
add_attachment matchbox-grpc       client.crt     "$HOME/.claude/homelab-matchbox/client.crt"
add_attachment matchbox-grpc       client.key     "$HOME/.claude/homelab-matchbox/client.key"
add_attachment cloudflare-ha-client ha-client.p12 "$HOME/.claude/cloudflare/ha-client.p12"
add_attachment cloudflare-ha-client ha-client.cert.pem "$HOME/.claude/cloudflare/ha-client.cert.pem"
add_attachment forgejo-keys        id_ed25519     "$HOME/.claude/homelab-forgejo/id_ed25519"
add_attachment forgejo-keys        id_ed25519.pub "$HOME/.claude/homelab-forgejo/id_ed25519.pub"
add_attachment forgejo-keys        gpg-private.asc "$HOME/.claude/homelab-forgejo/gpg-private.asc"
add_attachment forgejo-keys        gpg-public.asc "$HOME/.claude/homelab-forgejo/gpg-public.asc"
add_attachment github-reviewer-app private-key.pem "$HOME/.claude/homelab-github-reviewer/private-key.pem"
add_attachment github-runner-app   private-key.pem "$HOME/.claude/homelab-runner-app/private-key.pem"
# esphome flash secrets (wifi + OTA + api key — the !secret file, gitignored in-repo)
add_attachment droplet-esphome     secrets.yaml   "$(dirname "$0")/../esphome/config/secrets.yaml"

echo
echo "Done. Inspect with:"
echo "  devbox run -- keepassxc-cli ls -q --no-password -k $KEY $DB"
echo "Load secrets into a tofu session with:  source scripts/keepass-env.sh"
