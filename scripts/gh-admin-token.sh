#!/bin/sh
# gh-admin-token.sh — echo the teststuffstash ORG ADMIN token (Administration + Issues R/W) to stdout,
# read from the dedicated KeePass wallet. Shared by the out-of-jail github tools (github-tf.sh,
# github-apps.sh) so they resolve the admin creds identically. If GITHUB_TOKEN is already exported it
# wins (wallet skipped). See scripts/github-tf.sh header for the wallet layout.
#
# Wallet: ~/Documents/homelab-admin.kdbx, entry `github-homelab-admin`, keyfile-unlocked
# (~/Documents/homelab-admin.keyx). Override: GH_ADMIN_KP_DB / GH_ADMIN_KP_KEY (empty ⇒ password prompt)
# / GH_ADMIN_KP_ENTRY. Runs keepassxc-cli directly if present, else via devbox (mirrors keepass-env.sh).
set -eu

if [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"; exit 0; fi

GH_ADMIN_KP_DB="${GH_ADMIN_KP_DB:-$HOME/Documents/homelab-admin.kdbx}"
GH_ADMIN_KP_KEY="${GH_ADMIN_KP_KEY-$HOME/Documents/homelab-admin.keyx}"
GH_ADMIN_KP_ENTRY="${GH_ADMIN_KP_ENTRY:-github-homelab-admin}"
[ -f "$GH_ADMIN_KP_DB" ] || { echo "gh-admin-token: wallet $GH_ADMIN_KP_DB not found — set GH_ADMIN_KP_DB (and GH_ADMIN_KP_ENTRY / optional GH_ADMIN_KP_KEY), or export GITHUB_TOKEN yourself." >&2; exit 1; }

if command -v keepassxc-cli >/dev/null 2>&1; then _kp() { keepassxc-cli "$@"; }
else export DEVBOX_QUIET=1 NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"; _kp() { devbox run --quiet -- keepassxc-cli "$@"; }; fi

if [ -n "$GH_ADMIN_KP_KEY" ] && [ -f "$GH_ADMIN_KP_KEY" ]; then
  TOK="$(_kp show -q --no-password -k "$GH_ADMIN_KP_KEY" -a Password "$GH_ADMIN_KP_DB" "$GH_ADMIN_KP_ENTRY")"
else
  TOK="$(_kp show -q -a Password "$GH_ADMIN_KP_DB" "$GH_ADMIN_KP_ENTRY")"
fi
[ -n "$TOK" ] || { echo "gh-admin-token: wallet entry '$GH_ADMIN_KP_ENTRY' has no Password." >&2; exit 1; }
printf '%s' "$TOK"
