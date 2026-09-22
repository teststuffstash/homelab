#!/usr/bin/env bash
# mgmt-state-pull — bring the management box's state snapshots into the wallet cache, and VERIFY
# every one of them HERE (docs/tofu-state.md §Snapshots). The jail half of
# scripts/mgmt-state-snapshot.sh, which writes them on the box.
#
#   devbox run mgmt-state-pull            # fetch what is new, verify it, print the per-root newest
#   devbox run mgmt-state-pull -- --list  # compare box vs local, fetch nothing
#
# Runs by itself after every successful `mgmt-tf -- apply`, and by hand at session wind-down.
#
# WHY THE JAIL. The box is the ONLY writer of main's state (docs/tofu-state.md, the locking
# ruling), and it is one disk. The wallet cache is the copy the operator already backs up, and it
# sits outside both the box and the cluster — the one failure domain that survives losing either.
# Garage cannot be it: the state is what you rebuild the cluster FROM.
#
# WHY VERIFY TWICE. The box verified each snapshot's round trip when it wrote it. This re-verifies
# with a key that came from the WALLET, not from the box's env file — so a snapshot counts only
# once it has been decrypted by the copy of the secret you would actually restore with. A file
# that fails here is kept as `<name>.UNVERIFIED` and the run exits non-zero; it is never filed as
# good, and never deletes anything.
#
# One direction only. Nothing here writes to the box, and a snapshot is never restored by this
# script — a restore is a deliberate human act (§Snapshots has the recipe), or this becomes the
# second writer the locking ruling forbids.
set -euo pipefail

ROOT="${DEVBOX_PROJECT_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
HOST="${MGMT_HOST:-192.168.2.53}"
REMOTE_DIR=/var/lib/mgmt/state
DEST="${TOFU_STATE_BACKUP_DIR:-$HOME/.claude/homelab-tofu-state-backups}/mgmt"
LIST_ONLY=0; [ "${1:-}" = "--list" ] && LIST_ONLY=1
ITER=600000

CRED=""
for d in "${CLAUDE_CRED_DIR:-}" "$HOME/.claude" "$HOME/Projects/.claude-data"; do
  [ -n "$d" ] && [ -d "$d/homelab-pve-ssh" ] && CRED="$d" && break
done
[ -n "$CRED" ] || { echo "state-pull: cred dir not found (homelab-pve-ssh/)" >&2; exit 1; }

# The box's host key is PINNED from the wallet, never trusted on first use — the same rule
# mgmt-provision-secrets.sh follows. (The jail's ~/.ssh/known_hosts is not durable: it vanished
# mid-session on 2026-09-21, and a TOFU fallback is exactly what that invites.)
HOSTPUB="$CRED/homelab-mgmt/extra-files/etc/ssh/ssh_host_ed25519_key.pub"
[ -f "$HOSTPUB" ] || { echo "state-pull: no pinned host key at $HOSTPUB — run scripts/wallet-files.sh" >&2; exit 1; }
KH="$(mktemp)"; TMP="$(mktemp -d)"; trap 'rm -rf "$KH" "$TMP"' EXIT
echo "$HOST $(cut -d' ' -f1,2 "$HOSTPUB")" > "$KH"
# `-n`: this runs inside a `while read` over the listing, and an ssh that reads stdin eats the rest
# of that list — the first real run fetched one file and silently stopped (2026-09-21).
box() { ssh -n -o UserKnownHostsFile="$KH" -o StrictHostKeyChecking=yes -o BatchMode=yes \
          -i "$CRED/homelab-pve-ssh/id_ed25519" "root@$HOST" "$@"; }

tool() { ( cd "$ROOT" && devbox run --quiet -- "$@" ); }

# The passphrase from the WALLET (a pre-set env wins, as everywhere else in this repo).
if [ -z "${TOFU_STATE_PASSPHRASE:-}" ]; then
  KP=""
  for d in "${KP_DIR:-}" "$HOME/.claude/homelab-keepass" "$HOME/Projects/.claude-data/homelab-keepass"; do
    [ -n "$d" ] && [ -f "$d/homelab.kdbx" ] && KP="$d" && break
  done
  [ -n "$KP" ] || { echo "state-pull: no wallet found, and TOFU_STATE_PASSPHRASE is unset" >&2; exit 1; }
  TOFU_STATE_PASSPHRASE="$(tool keepassxc-cli show -q --no-password -k "$KP/homelab.keyx" -a Password "$KP/homelab.kdbx" tofu-state-passphrase 2>/dev/null || true)"
  [ -n "$TOFU_STATE_PASSPHRASE" ] || { echo "state-pull: wallet entry tofu-state-passphrase is empty" >&2; exit 1; }
fi
export TOFU_STATE_PASSPHRASE

remote_list="$(box "cd $REMOTE_DIR && find . -path '*/snapshots/*' -type f -printf '%P\n' | sort")" \
  || { echo "state-pull: could not list $HOST:$REMOTE_DIR" >&2; exit 1; }
mkdir -p "$DEST"; chmod 700 "$DEST"

# name = <root>-<UTC>-s<serial>-<lineage8>.<ext>
verify() {
  # $1 = the file to check, $2 = the snapshot's NAME (the file is fetched to a temp path, so its own
  # basename says nothing — the first run judged every file by the name "in").
  local f="$1" base="$2" serial lin8 plain got_s got_l
  serial="$(printf '%s' "$base" | sed -nE 's/.*-s([0-9]+)-[0-9a-f]{8}\..*/\1/p')"
  lin8="$(printf '%s' "$base" | sed -nE 's/.*-s[0-9]+-([0-9a-f]{8})\..*/\1/p')"
  [ -n "$serial" ] && [ -n "$lin8" ] || { echo "unparseable name"; return 1; }
  case "$base" in
    *.tfstate.enc)
      plain="$TMP/plain"
      tool openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" -md sha256 -pass env:TOFU_STATE_PASSPHRASE -in "$f" > "$plain" 2>/dev/null \
        || { echo "does not decrypt with the wallet passphrase"; return 1; } ;;
    *.tfstate)
      plain="$f"
      [ "$(tool jq -r 'has("encrypted_data")' "$f" 2>/dev/null)" = true ] || { echo "not a tofu-encrypted envelope"; return 1; } ;;
    *) echo "unknown extension"; return 1 ;;
  esac
  got_s="$(tool jq -r .serial "$plain" 2>/dev/null || true)"
  got_l="$(tool jq -r .lineage "$plain" 2>/dev/null || true)"
  rm -f "$TMP/plain"
  [ "$got_s" = "$serial" ] && [ "${got_l:0:8}" = "$lin8" ] || { echo "serial/lineage mismatch (file: s$got_s ${got_l:0:8})"; return 1; }
}

new=0 bad=0
while read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$DEST/$rel" ] && continue
  if [ "$LIST_ONLY" = 1 ]; then echo "  would fetch: $rel"; new=$((new+1)); continue; fi
  mkdir -p "$DEST/$(dirname "$rel")"; chmod 700 "$DEST/$(dirname "$rel")"
  box "cat $REMOTE_DIR/$rel" > "$TMP/in" || { echo "state-pull: could not fetch $rel" >&2; bad=$((bad+1)); continue; }
  if why="$(verify "$TMP/in" "$(basename "$rel")")"; then
    install -m 600 "$TMP/in" "$DEST/$rel"; echo "  pulled + verified: $rel"; new=$((new+1))
  else
    install -m 600 "$TMP/in" "$DEST/$rel.UNVERIFIED"; echo "  ✗ $rel: $why — kept as .UNVERIFIED" >&2; bad=$((bad+1))
  fi
done <<< "$remote_list"

echo "state-pull: $new new, $bad failed — newest per root, local:"
for d in "$DEST"/*/snapshots; do
  [ -d "$d" ] || continue
  printf '  %-14s %s\n' "$(basename "$(dirname "$d")")" "$(ls -1 "$d" | grep -v UNVERIFIED | tail -1)"
done
[ "$bad" = 0 ]
