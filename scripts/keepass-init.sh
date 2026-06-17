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
add_secret grafana-admin-password "$(file_or "$HOME/.claude/homelab-ha/grafana_admin_password" REPLACE)"
add_secret ha-prometheus-token    "$(file_or "$HOME/.claude/homelab-ha/prometheus_llat" REPLACE)"

echo
echo "Done. Inspect with:"
echo "  devbox run -- keepassxc-cli ls -q --no-password -k $KEY $DB"
echo "Load secrets into a tofu session with:  source scripts/keepass-env.sh"
