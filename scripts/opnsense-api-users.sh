#!/usr/bin/env bash
# Create/converge the OPNsense API users (ansible/opnsense-users.yml, FU-013) on the PRODUCTION
# router and route any key the play mints to where docs/secrets.md says it lives:
#   every user        -> the KeePass wallet, entries opnsense-<user>-api-key / -api-secret (canonical)
#   backup-puller     -> also Infisical OPNSENSE_BACKUP_PULLER_API_{KEY,SECRET} (ESO delivers it to
#                        the in-cluster puller, argocd/resources/opnsense-config-backup/)
#
#   bash scripts/opnsense-api-users.sh [extra ansible-playbook args, e.g. --check --diff]
#
# A live router write: run it inside a maintenance window. The play runs with root's key through
# scripts/opnsense-playbook.sh (user management needs it). OPNsense returns an API secret exactly
# once, so the play writes a fresh pair into a private tmpdir (0600) and this script moves it into
# the stores and deletes the tmpdir — the values never reach argv of anything but keepassxc's stdin
# and the infisical-secret call, and never a log.
#
# Idempotent: a user that already has a key gets none. To ROTATE one: delete its key on the router
# (GET auth/user/search_api_key -> POST auth/user/del_api_key/<id>) and re-run; the new pair
# overwrites the wallet entries (the router just proved the old ones dead).
set -euo pipefail
cd "$(dirname "$0")/.."

KDB="$HOME/.claude/homelab-keepass/homelab.kdbx"
KKEY="$HOME/.claude/homelab-keepass/homelab.keyx"
[ -f "$KDB" ] || { echo "no wallet at $KDB — the minted keys would have nowhere to go" >&2; exit 1; }

kp() { DEVBOX_QUIET=1 devbox run --quiet -- keepassxc-cli "$@"; }
kp_has() { kp show -q --no-password -k "$KKEY" "$KDB" "$1" >/dev/null 2>&1; }
kp_get() { kp show -q --no-password -k "$KKEY" -a Password "$KDB" "$1" 2>/dev/null; }
kp_put() { # kp_put <entry> <value-file>  (value via stdin, never argv)
  if kp_has "$1"; then
    echo "  ! $1 exists — overwriting (the router had no key for this user, so the old value is dead)"
    kp edit -q --no-password -k "$KKEY" -p "$KDB" "$1" < "$2" >/dev/null
  else
    kp add -q --no-password -k "$KKEY" -p "$KDB" "$1" < "$2" >/dev/null
  fi
  [ "$(kp_get "$1")" = "$(cat "$2")" ] || { echo "wallet write of $1 did not read back" >&2; exit 1; }
  echo "  + wallet $1"
}

SINK="$(mktemp -d)"; chmod 700 "$SINK"
trap 'find "$SINK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$SINK"' EXIT

bash scripts/opnsense-playbook.sh ansible/opnsense-users.yml -e "opnsense_users_key_sink=$SINK" "$@"

minted=0
for keyf in "$SINK"/*.key; do
  [ -e "$keyf" ] || continue
  user="$(basename "$keyf" .key)"; secf="$SINK/$user.secret"
  [ -s "$keyf" ] && [ -s "$secf" ] || { echo "incomplete pair for $user in the sink" >&2; exit 1; }
  echo "minted a key for $user:"
  kp_put "opnsense-$user-api-key" "$keyf"
  kp_put "opnsense-$user-api-secret" "$secf"
  case "$user" in
    backup-puller)
      # Base64 values (no `$`), so infisical-secret's shell-expansion caveat does not bite.
      devbox run infisical-secret "OPNSENSE_BACKUP_PULLER_API_KEY=$(cat "$keyf")" \
                                  "OPNSENSE_BACKUP_PULLER_API_SECRET=$(cat "$secf")" >/dev/null
      echo "  + infisical OPNSENSE_BACKUP_PULLER_API_{KEY,SECRET}" ;;
  esac
  minted=$((minted + 1))
done
echo "done: $minted key pair(s) minted and stored"
