#!/usr/bin/env bash
# Store minted Cloudflare tokens where their consumers expect them — the scripted version of the
# old post-apply checklist (operator, 2026-08-08: "checklist is nice, script would be better").
# Called automatically by scripts/cloudflare-token-tf.sh after `apply` (skip: CF_STORE=0), safe
# to run standalone any time:
#
#     bash scripts/cloudflare-token-store.sh
#
# Per minted output (skipped silently if the output does not exist in state yet):
#   1. ordinary wallet entry  — UPDATED in place (the mint is the source of truth; this is the
#      deliberate opposite of wallet-files.sh's never-overwrite cache semantics)
#   2. cred-cache file        — overwritten, mode 600 (what jail/host consumers read)
#   3. Infisical              — via scripts/infisical-secret.sh (cluster consumers via ESO);
#      needs cluster reachability — failures WARN, never abort the wallet/file stores.
# This also makes the FU-156 renewal runbook exactly two commands: apply, then nothing — the
# wrapper stores. No token value is ever echoed.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ── mapping: tofu output → wallet entry → cache file (rel. to cred root) → Infisical key ("" = none)
MAP="
observability_read_token cloudflare-observability-read cloudflare/observability-read CLOUDFLARE_OBSERVABILITY_READ
tofu_apply_token         cloudflare-write-key          cloudflare/write-key          -
acme_dns_token           cloudflare-acme-token         cloudflare/acme-token         -
ingress_write_token      cloudflare-ingress-write      cloudflare/ingress-write      CLOUDFLARE_INGRESS_WRITE
inventory_read_token     cloudflare-inventory-read     cloudflare/inventory-read     CLOUDFLARE_INVENTORY_READ
"

# cred root + wallet, same dual-path resolution as wallet-files.sh
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -f "$d/homelab-keepass/homelab.kdbx" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "cloudflare-token-store: ordinary wallet not found — run scripts/keepass-init.sh" >&2; exit 1; }
DB="$CRED/homelab-keepass/homelab.kdbx"; KEYF="$CRED/homelab-keepass/homelab.keyx"
export DEVBOX_QUIET=1 NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
if command -v keepassxc-cli >/dev/null 2>&1; then kp() { keepassxc-cli "$@"; }; else kp() { (cd "$ROOT" && devbox run --quiet -- keepassxc-cli "$@"); }; fi
if command -v tofu >/dev/null 2>&1; then tf() { tofu "$@"; }; else tf() { (cd "$ROOT" && devbox run --quiet -- tofu "$@"); }; fi

wallet_put() { # <entry> <value> — add or update
  local entry="$1" value="$2"
  if kp show -q --no-password -k "$KEYF" "$DB" "$entry" >/dev/null 2>&1; then
    printf '%s\n' "$value" | kp edit -q --no-password -k "$KEYF" --password-prompt "$DB" "$entry" >/dev/null \
      && echo "  ~ wallet $entry (updated)"
  else
    printf '%s\n' "$value" | kp add -q --no-password -k "$KEYF" --password-prompt "$DB" "$entry" >/dev/null \
      && echo "  + wallet $entry (added)"
  fi
}

stored_any=0
printf '%s\n' "$MAP" | while read -r out entry cache inf; do
  [ -n "$out" ] || continue
  v="$(tf -chdir="$ROOT/tofu/cloudflare-token" output -raw "$out" 2>/dev/null || true)"
  [ -n "$v" ] || { echo "  · $out — no such output in state, skipped"; continue; }
  wallet_put "$entry" "$v"
  dest="$CRED/$cache"
  mkdir -p "$(dirname "$dest")" && chmod 700 "$(dirname "$dest")"
  printf '%s\n' "$v" > "$dest" && chmod 600 "$dest" && echo "  ~ cache $dest"
  if [ "$inf" != "-" ]; then
    if bash "$HERE/infisical-secret.sh" "$inf=$v" >/dev/null 2>&1; then
      echo "  ~ infisical $inf"
    else
      echo "  ! infisical $inf FAILED (cluster unreachable?) — rerun: bash scripts/infisical-secret.sh $inf=<value>" >&2
    fi
  fi
  stored_any=1
done
echo "cloudflare-token-store: done"
