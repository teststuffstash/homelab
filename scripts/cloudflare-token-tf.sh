#!/bin/sh
# devbox cloudflare-token-tofu wrapper — the Cloudflare twin of scripts/github-tf.sh.
# Assembles the ACCOUNT-ADMIN token `tofu -chdir=tofu/cloudflare-token` needs, then runs tofu.
# One command, host-only by construction (the admin wallet does not exist in the jail):
#
#     devbox run cloudflare-token-tofu plan      # or: apply / <any tofu subcommand + args>
#
# The account-admin token lives in the SAME separate host-only wallet as the GitHub org-admin
# token (~/Documents/homelab-admin.kdbx, keyfile ~/Documents/homelab-admin.keyx — non-interactive),
# entry `cloudflare-account-admin`. An already-set CLOUDFLARE_API_TOKEN wins (wallet skipped).
# Override if it moves:
#   CF_ADMIN_KP_DB=<path/to.kdbx>  CF_ADMIN_KP_KEY=<path/to.keyx, empty ⇒ password prompt>  CF_ADMIN_KP_ENTRY=<title>
#
# MINTED tokens flow the other way, into the ORDINARY wallet + caches (keepass-init.sh entries,
# wallet-files.sh materialization) — this script only ever needs the mint credential.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ -z "${CLOUDFLARE_API_TOKEN:-}" ]; then
  DB="${CF_ADMIN_KP_DB:-$HOME/Documents/homelab-admin.kdbx}"
  KEYF="${CF_ADMIN_KP_KEY:-$HOME/Documents/homelab-admin.keyx}"
  ENTRY="${CF_ADMIN_KP_ENTRY:-cloudflare-account-admin}"
  [ -f "$DB" ] || { echo "cloudflare-token-tf: admin wallet $DB not found — this root runs on the HOST only" >&2; exit 1; }
  if command -v keepassxc-cli >/dev/null 2>&1; then _kp() { keepassxc-cli "$@"; }; else _kp() { (cd "$ROOT" && devbox run --quiet -- keepassxc-cli "$@"); }; fi
  if [ -n "$KEYF" ] && [ -f "$KEYF" ]; then
    CLOUDFLARE_API_TOKEN="$(_kp show -q --no-password -k "$KEYF" -a Password "$DB" "$ENTRY")"
  else
    CLOUDFLARE_API_TOKEN="$(_kp show -q -a Password "$DB" "$ENTRY")"
  fi
  [ -n "$CLOUDFLARE_API_TOKEN" ] || { echo "cloudflare-token-tf: entry '$ENTRY' empty/missing in $DB" >&2; exit 1; }
  export CLOUDFLARE_API_TOKEN
fi

cd "$ROOT/tofu/cloudflare-token"
tofu "$@"
rc=$?

case "${1:-}" in apply)
  echo ""
  echo "→ minted-token bookkeeping (FU-001 pattern): store each new/rotated output THREE places —"
  echo "   1. ordinary wallet entry (scripts/keepass-init.sh names, e.g. cloudflare-observability-read)"
  echo "   2. jail cache file      (~/.claude/cloudflare/<name> — wallet-files.sh regenerates it)"
  echo "   3. Infisical            (cluster consumers via ESO, e.g. CLOUDFLARE_OBSERVABILITY_READ)"
  echo "   e.g.: tofu output -raw observability_read_token"
;; esac
exit $rc
