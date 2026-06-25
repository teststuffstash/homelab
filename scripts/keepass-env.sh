# shellcheck shell=bash
# Source me:  source scripts/keepass-env.sh
#
# Exports the TF_VAR_* the main tofu/ root needs, read live from the homelab
# bootstrap KeePass wallet (scripts/keepass-init.sh). Replaces the old
# `cat ~/.claude/homelab-ha/...` lines in the tofu-apply runbook with one source.
#
# Returns non-zero (without killing your shell) if the wallet is missing.

# Resolve the wallet dir: explicit KP_DIR, else jail (~/.claude) or host (~/Projects/.claude-data).
# Same dual-path trick as scripts/garage-s3.sh, so `source`-ing works in both without an override.
_kp_dir=""
for _d in "${KP_DIR:-}" "$HOME/.claude/homelab-keepass" "$HOME/Projects/.claude-data/homelab-keepass"; do
  [ -n "$_d" ] && [ -f "$_d/homelab.kdbx" ] && _kp_dir="$_d" && break
done
_kp_db="$_kp_dir/homelab.kdbx"
_kp_key="$_kp_dir/homelab.keyx"
export DEVBOX_QUIET=1
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

if [ ! -f "$_kp_db" ]; then
  echo "keepass-env: wallet $_kp_db not found — run: bash scripts/keepass-init.sh" >&2
  return 1 2>/dev/null || exit 1
fi

if command -v keepassxc-cli >/dev/null 2>&1; then
  _kp() { keepassxc-cli "$@"; }
else
  _kp() { devbox run --quiet -- keepassxc-cli "$@"; }
fi

# _kp_get <entry-title>  → prints the Password field (clean stdout)
_kp_get() { _kp show -q --no-password -k "$_kp_key" -a Password "$_kp_db" "$1" 2>/dev/null; }

export TF_VAR_grafana_admin_password="$(_kp_get grafana-admin-password)"
export TF_VAR_ha_prometheus_token="$(_kp_get ha-prometheus-token)"
export TF_VAR_infisical_encryption_key="$(_kp_get infisical-encryption-key)"
export TF_VAR_infisical_auth_secret="$(_kp_get infisical-auth-secret)"
export TF_VAR_infisical_db_password="$(_kp_get infisical-db-password)"
export TF_VAR_argocd_github_pat="$(_kp_get argocd-github-pat)"
export TF_VAR_infisical_admin_email="$(_kp_get infisical-admin-email)"
export TF_VAR_infisical_admin_password="$(_kp_get infisical-admin-password)"
export TF_VAR_forgejo_runner_token="$(_kp_get forgejo-runner-token)"

echo "keepass-env: exported TF_VAR_{grafana_admin_password,ha_prometheus_token,infisical_*,argocd_github_pat,infisical_admin_*,forgejo_runner_token} from $_kp_db" >&2
unset -f _kp _kp_get
unset _kp_dir _kp_db _kp_key _d
