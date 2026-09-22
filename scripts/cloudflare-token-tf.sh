#!/bin/sh
# devbox cloudflare-token-tofu wrapper — the Cloudflare twin of scripts/github-tf.sh.
# Assembles the ACCOUNT-ADMIN token `tofu -chdir=tofu/cloudflare-token` needs, then runs tofu.
# One command, host-only by construction (the admin wallet does not exist in the jail):
#
#     devbox run cloudflare-token-tofu plan      # or: apply / <any tofu subcommand + args>
#     CF_INCLUDE_READ_ALL=1 devbox run cloudflare-token-tofu apply   # include the read-all token (see below)
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

# The read-all token's STANDING group-order permutation (docs/cloudflare.md gotcha 3 addendum,
# FU-239 — the API's order for its 146+45 groups is arbitrary, not fixed by provider 5.25.0):
# plan/apply EXCLUDE that resource by default so the rest of the root reads clean, then a
# separate targeted plan reports whether it carries REAL (+/-) group changes — the catalog
# widening the filter exists to pick up — so nothing is skipped silently. Off switches:
# CF_INCLUDE_READ_ALL=1, or your own -target/-exclude on the command line.
READ_ALL='cloudflare_api_token.jail_read_all[0]'
excluded=0
case "${1:-}" in plan|apply)
  if [ "${CF_INCLUDE_READ_ALL:-0}" != 1 ] && ! printf '%s\n' "$@" | grep -qE '^-(target|exclude)='; then
    set -- "$@" "-exclude=$READ_ALL"; excluded=1
  fi ;;
esac
tofu "$@"
rc=$?
if [ "$excluded" -eq 1 ] && [ "$rc" -eq 0 ]; then
  echo ""
  echo "→ $READ_ALL was EXCLUDED (standing permutation, FU-239) — checking it for real changes"
  prc=0; out="$(tofu plan -input=false -no-color -detailed-exitcode "-target=$READ_ALL" 2>&1)" || prc=$?  # set -e: rc 2 = "has changes", not a failure (2026-09-22 it killed the script before the store step)
  real="$(printf '%s\n' "$out" | grep -cE '^[[:space:]]+[+-] \{' || true)"
  if [ "$prc" -eq 2 ] && [ "$real" -gt 0 ]; then
    echo "  ⚠ $real ADDED/REMOVED group element(s) — a real catalog change; review + apply with: CF_INCLUDE_READ_ALL=1 devbox run cloudflare-token-tofu plan|apply"
    printf '%s\n' "$out" | grep -E '^[[:space:]]+[+-] \{' -A1 | grep -oE 'id = "[0-9a-f]+"' | sed 's/^/    /'
  elif [ "$prc" -eq 2 ]; then echo "  permutation only (~ id lines, no +/- elements) — nothing to do"
  elif [ "$prc" -eq 0 ]; then echo "  clean"
  else echo "  targeted plan failed (rc=$prc) — run it by hand: tofu plan -target=$READ_ALL"; fi
fi

case "${1:-}" in apply)
  if [ "${CF_STORE:-1}" = "1" ] && [ "$rc" -eq 0 ]; then
    echo ""
    echo "→ storing minted tokens (wallet + cred cache + Infisical) — CF_STORE=0 to skip"
    bash "$ROOT/scripts/cloudflare-token-store.sh" || \
      echo "→ store FAILED — run manually: bash scripts/cloudflare-token-store.sh" >&2
  fi
;; esac
exit $rc
