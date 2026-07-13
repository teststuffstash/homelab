#!/usr/bin/env bash
# Materialize file-shaped Tier-0 secrets from the KeePass wallet back onto disk (FU-001).
#
# The wallet (scripts/keepass-init.sh) is the STORE; the legacy ~/.claude/<dir>/<file> paths that
# tofu/ansible/scripts consume are now a disposable CACHE this script regenerates. Only MISSING
# files are written (never overwrites — a freshly rotated local file wins until the wallet entry
# is updated), mode 600, dirs 700. Consumers keep their paths; deleting a cache dir is always
# recoverable with one run of this script.
#
#   bash scripts/wallet-files.sh          # materialize whatever is absent
#
# Called automatically by scripts/tf.sh and scripts/github-tf.sh so tofu runs self-heal.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Resolve the cred root (the dir holding homelab-keepass/) — jail vs host, like keepass-env.sh.
CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -f "$d/homelab-keepass/homelab.kdbx" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "wallet-files: wallet not found — run scripts/keepass-init.sh" >&2; exit 1; }
DB="$CRED/homelab-keepass/homelab.kdbx"
KEYF="$CRED/homelab-keepass/homelab.keyx"

export DEVBOX_QUIET=1
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"
if command -v keepassxc-cli >/dev/null 2>&1; then
  kp() { keepassxc-cli "$@"; }
else
  kp() { (cd "$HERE/.." && devbox run --quiet -- keepassxc-cli "$@"); }
fi

# att <entry> <attachment> <dest>   — export an attachment to dest if dest is missing.
# NEVER --stdout: it mangles binary attachments (the .p12) — export straight to the file.
att() {
  local entry="$1" name="$2" dest="$3"
  [ -f "$dest" ] && return 0
  mkdir -p "$(dirname "$dest")" && chmod 700 "$(dirname "$dest")"
  if kp attachment-export -q --no-password -k "$KEYF" "$DB" "$entry" "$name" "$dest" 2>/dev/null; then
    chmod 600 "$dest"; echo "  + $dest  (← $entry/$name)"
  else
    echo "  ! $dest — wallet entry $entry/$name missing, skipped" >&2
  fi
}
# val <entry> <dest>   — write a value entry to dest (newline-terminated) if dest is missing.
val() {
  local entry="$1" dest="$2" v
  [ -f "$dest" ] && return 0
  v="$(kp show -q --no-password -k "$KEYF" -a Password "$DB" "$entry" 2>/dev/null || true)"
  [ -n "$v" ] || { echo "  ! $dest — wallet entry $entry missing, skipped" >&2; return 0; }
  mkdir -p "$(dirname "$dest")" && chmod 700 "$(dirname "$dest")"
  printf '%s\n' "$v" > "$dest" && chmod 600 "$dest" && echo "  + $dest  (← $entry)"
}

att pve-ssh-seed        id_ed25519      "$CRED/homelab-pve-ssh/id_ed25519"
att pve-ssh-seed        id_ed25519.pub  "$CRED/homelab-pve-ssh/id_ed25519.pub"
att matchbox-grpc       ca.crt          "$CRED/homelab-matchbox/ca.crt"
att matchbox-grpc       client.crt      "$CRED/homelab-matchbox/client.crt"
att matchbox-grpc       client.key      "$CRED/homelab-matchbox/client.key"
att github-runner-app   private-key.pem "$CRED/homelab-runner-app/private-key.pem"
att github-reviewer-app private-key.pem "$CRED/homelab-github-reviewer/private-key.pem"
val github-reviewer-app-id              "$CRED/homelab-github-reviewer/app-id"
val github-reviewer-installation-id     "$CRED/homelab-github-reviewer/installation-id"
val github-reviewer-slug                "$CRED/homelab-github-reviewer/slug"
att cloudflare-ha-client ha-client.p12       "$CRED/cloudflare/ha-client.p12"
att cloudflare-ha-client ha-client.cert.pem  "$CRED/cloudflare/ha-client.cert.pem"
val cloudflare-ha-client-p12-password        "$CRED/cloudflare/ha-client.p12.password"
att forgejo-keys        id_ed25519      "$CRED/homelab-forgejo/id_ed25519"
att forgejo-keys        id_ed25519.pub  "$CRED/homelab-forgejo/id_ed25519.pub"   # snore-recorder rpi-usb.sh reads this
att forgejo-keys        gpg-private.asc "$CRED/homelab-forgejo/gpg-private.asc"
att forgejo-keys        gpg-public.asc  "$CRED/homelab-forgejo/gpg-public.asc"
# esphome flash secrets (!secret refs in esphome/config/*.yaml) — repo-relative, gitignored.
att droplet-esphome     secrets.yaml    "$HERE/../esphome/config/secrets.yaml"
