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
# scripts/opnsense-playbook.sh (OPN_AS_ROOT=1 — user management is the one root act; every other
# play runs as `automation`). A privilege change converges on the existing user and mints NOTHING
# (keys are per user, not per privilege set). OPNsense returns an API secret exactly
# once, so the play writes a fresh pair into a private tmpdir (0600) and this script moves it into
# the stores and deletes the tmpdir — the values never reach argv of anything but keepassxc's stdin
# and the infisical-secret call, and never a log.
#
# One user = one key pair, identical on EVERY router node and in the wallet (the CARP pair has no
# config sync): the play mints a missing key ONCE, on the first node in inventory order, and
# installs that same pair on the other node; it refuses before any write when the nodes hold
# different keys or a node holds a key the wallet lacks or contradicts — this script hands it the
# wallet's PUBLIC halves for that check (roles/opnsense-users, filter_plugins/opn_user_keys.py).
# `--check` mints nothing and prints the per-node plan ("<node>: firmware mint · automation ok").
#
# Idempotent: a user every node holds a key for gets none. To ROTATE one: delete its key on EVERY
# node (GET auth/user/search_api_key -> POST auth/user/del_api_key/<id>) and re-run; the new pair
# overwrites the wallet entries (the nodes just proved the old ones dead).
#
# A FAILED run still stores what it minted: the play's exit code is held, whatever reached the sink
# goes to the wallet (+ Infisical), and only then does the script exit with the play's code. A key
# minted on the first node is never lost to a later failure (the install on the other node, the
# end-state checks); the re-run finds the wallet holding that node's pair and installs it on the rest.
# Self-test: scripts/opnsense-api-users-test.sh (stubbed play + wallet).
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

# The wallet's public halves, for the play's "the wallet holds the pair a node holds" check. Read
# from group_vars (the one list); a user with no wallet entry is simply absent from the map.
WALLET_KEYS="$SINK/.wallet-keys.json"
{
  printf '{"opnsense_users_wallet_keys": {'; sep=''
  for user in $(DEVBOX_QUIET=1 devbox run --quiet -- yq -r '.opnsense_api_users[].name' ansible/group_vars/opnsense.yml); do
    k="$(kp_get "opnsense-$user-api-key" || true)"
    [ -n "$k" ] || continue
    printf '%s"%s": "%s"' "$sep" "$user" "$k"; sep=', '
  done
  printf '}}\n'
} > "$WALLET_KEYS"
chmod 600 "$WALLET_KEYS"

rc=0
OPN_AS_ROOT=1 bash scripts/opnsense-playbook.sh ansible/opnsense-users.yml \
  -e "opnsense_users_key_sink=$SINK" -e "@$WALLET_KEYS" "$@" || rc=$?
rm -f "$WALLET_KEYS"

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
if [ "$rc" -ne 0 ]; then
  echo "the users play FAILED (rc=$rc); the $minted pair(s) it minted are stored above — fix the cause and re-run (the plan installs a stored pair on the nodes that lack it)" >&2
  exit "$rc"
fi
