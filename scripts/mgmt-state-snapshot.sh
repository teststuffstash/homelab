#!/usr/bin/env bash
# mgmt-state-snapshot — dated, encrypted, verified snapshots of every tofu root's state, ON the
# management box (docs/tofu-state.md §Snapshots, FU-012). Runs on the box; the jail's half is
# scripts/mgmt-state-pull.sh.
#
#   mgmt-state-snapshot.sh                  # every root: main + each Garage-backed root
#   mgmt-state-snapshot.sh main             # one root
#   mgmt-state-snapshot.sh --lock-held main # called from INSIDE a span that already holds the lock
#
# WHY THIS EXISTS. Until 2026-09-21 there were no snapshots of any state at all. `main` lives only
# at /var/lib/mgmt/state/main/terraform.tfstate on this box's one disk (tofu's own .backup sibling
# is one generation back, same disk); the four migrated roots are one object each in Garage,
# overwritten in place, and the bucket has no versioning (`get-bucket-versioning` → empty). The
# only dated copies were the ones tofu-state-migrate.sh wrote once, at migration — main's was 55
# serials stale the day this was written. A reinstall of this box, or the loss of its disk, would
# have meant importing the whole cluster back into an empty state.
#
# WHAT A SNAPSHOT IS.
#   <root>-<UTC>-s<serial>-<lineage8>.<ext>   under /var/lib/mgmt/state/<root>/snapshots/, 0600
#   main (plaintext on disk)      → .tfstate.enc — openssl, AES-256-CBC, PBKDF2-SHA256 600k
#                                   iterations, keyed by the SAME wallet passphrase the migrated
#                                   roots' native encryption uses (tofu-state-passphrase). No new
#                                   key: one secret to hold, one to lose (docs/tofu-state.md warns
#                                   that losing it loses every migrated root already).
#   a Garage root (tofu-encrypted) → .tfstate — the object's bytes as they are. It is already
#                                   ciphertext under that passphrase (serial/lineage stay readable
#                                   in the envelope), so wrapping it again buys nothing; restoring
#                                   it is putting the object back. A Garage object that is NOT
#                                   encrypted (it has a `resources` key) is encrypted like main.
#
# Every snapshot is VERIFIED before it is kept: the file is decrypted (or, for an envelope, parsed)
# and its serial + lineage must match what was read. A snapshot nobody has ever restored is a hope;
# this makes every one of them a completed round trip at the moment it is written.
#
# IDEMPOTENT: a root whose newest snapshot already carries the same serial and lineage is skipped.
# So it is safe — and meant — to call this after every apply AND on a timer: the apply hook makes it
# immediate, the timer catches the applies that happen elsewhere (the Garage roots are applied from
# the host and the jail, not from here).
#
# ⚠ AES-CBC has no MAC. That is acceptable for THIS threat: the copy is only as trusted as the
# machine that holds it, root on this box can already rewrite the live state, and the jail's pull
# re-verifies each file independently. It is NOT an integrity seal against an attacker in between.
set -euo pipefail

REPO="${REPO:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${MGMT_STATE_DIR:-/var/lib/mgmt/state}"
LOCK="${MGMT_LOCK:-/var/lib/mgmt/sentinel/.lock}"
KEEP="${SNAPSHOT_KEEP:-50}"      # per root; ~1.7 MB each for main — cheap, and a cache that has to
                                 # be reclaimed often is undersized (the oversize-caches rule)
BUCKET="${TOFU_STATE_BUCKET:-homelab-tofu-state}"
ITER=600000

log() { printf '%s snapshot: %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
tool() { ( cd "$REPO" && devbox run --quiet -- "$@" ); }

LOCK_HELD=0
[ "${1:-}" = "--lock-held" ] && { LOCK_HELD=1; shift; }

[ -n "${TOFU_STATE_PASSPHRASE:-}" ] || { log "FATAL TOFU_STATE_PASSPHRASE unset — the box env file carries it (docs/management-box.md §Credentials)"; exit 1; }
export TOFU_STATE_PASSPHRASE

# The Garage-backed roots are whatever tofu/*/backend.tf say they are: a root migrated tomorrow is
# covered without touching this file.
garage_roots() {
  grep -hoE 'key[[:space:]]*=[[:space:]]*"[^"/]+/terraform\.tfstate"' "$REPO"/tofu/*/backend.tf 2>/dev/null \
    | sed -E 's/.*"([^"/]+)\/terraform\.tfstate"/\1/' | sort -u
}

if [ $# -gt 0 ]; then ROOTS=("$@"); else mapfile -t ROOTS < <(printf 'main\n'; garage_roots); fi

# Standalone runs take the loops' lock, so no apply can be mid-write while main is read. From
# INSIDE mgmt-tf / mgmt-apply the caller already holds it on fd 9 — flocking again from this child
# would block on our own parent.
if [ "$LOCK_HELD" = 0 ]; then
  exec 8>"$LOCK"; flock -w 600 8 || { log "lock busy for 10 min — not snapshotting"; exit 1; }
fi

enc()  { tool openssl enc -e -aes-256-cbc -pbkdf2 -iter "$ITER" -md sha256 -salt -pass env:TOFU_STATE_PASSPHRASE -in "$1" -out "$2"; }
dec()  { tool openssl enc -d -aes-256-cbc -pbkdf2 -iter "$ITER" -md sha256 -pass env:TOFU_STATE_PASSPHRASE -in "$1"; }
field() { tool jq -r "$1" "$2" 2>/dev/null || true; }

snap_one() {
  local root="$1" src tmpdir serial lineage enc_needed ext dir name newest
  tmpdir="$(mktemp -d)"; trap 'rm -rf "$tmpdir"' RETURN
  if [ "$root" = main ]; then
    src="$STATE_DIR/main/terraform.tfstate"
    [ -f "$src" ] || { log "$root: no state at $src — skipped"; return 0; }
    cp "$src" "$tmpdir/state"
  else
    ( set +u; cd "$REPO" && TOFU_STATE_ROOT_DIR="$REPO/tofu/$root" . scripts/tofu-state-env.sh >/dev/null 2>&1
      devbox run --quiet -- aws s3 cp --only-show-errors "s3://$BUCKET/$root/terraform.tfstate" "$tmpdir/state" ) \
      || { log "$root: could not fetch s3://$BUCKET/$root/terraform.tfstate — skipped"; return 0; }
  fi
  serial="$(field .serial "$tmpdir/state")"; lineage="$(field .lineage "$tmpdir/state")"
  # A torn read (an apply writing as we copied) or a non-state file is refused here, not archived.
  [ -n "$serial" ] && [ "$serial" != null ] && [ -n "$lineage" ] && [ "$lineage" != null ] \
    || { log "$root: not a readable tfstate (serial='$serial') — skipped"; return 0; }
  if [ "$root" = main ] || [ "$(field 'has("resources")' "$tmpdir/state")" = true ]; then
    enc_needed=1; ext="tfstate.enc"
  else
    enc_needed=0; ext="tfstate"
    [ "$(field 'has("encrypted_data")' "$tmpdir/state")" = true ] \
      || { log "$root: neither plaintext state nor a tofu-encrypted envelope — skipped"; return 0; }
  fi
  dir="$STATE_DIR/$root/snapshots"; mkdir -p "$dir"; chmod 700 "$dir"
  newest="$(ls -1 "$dir"/"$root"-*."$ext" 2>/dev/null | tail -1 || true)"
  case "$newest" in
    *"-s$serial-${lineage:0:8}.$ext") log "$root: s$serial unchanged since $(basename "$newest") — nothing to do"; return 0 ;;
  esac
  name="$root-$(date -u +%Y%m%dT%H%M%SZ)-s$serial-${lineage:0:8}.$ext"
  if [ "$enc_needed" = 1 ]; then
    enc "$tmpdir/state" "$tmpdir/out" || { log "$root: encryption FAILED — nothing kept"; return 1; }
    dec "$tmpdir/out" > "$tmpdir/check" || { log "$root: the new snapshot does not DECRYPT — nothing kept"; return 1; }
  else
    cp "$tmpdir/state" "$tmpdir/out"; cp "$tmpdir/out" "$tmpdir/check"
  fi
  [ "$(field .serial "$tmpdir/check")" = "$serial" ] && [ "$(field .lineage "$tmpdir/check")" = "$lineage" ] \
    || { log "$root: round-trip mismatch — nothing kept"; return 1; }
  install -m 600 "$tmpdir/out" "$dir/$name"
  log "$root: kept $name (verified round trip)"
  # keep the newest $KEEP; names sort by time within a root
  ls -1 "$dir"/"$root"-* 2>/dev/null | head -n -"$KEEP" | while read -r old; do rm -f "$old"; log "$root: pruned $(basename "$old")"; done
}

rc=0
for r in "${ROOTS[@]}"; do snap_one "$r" || rc=1; done
exit $rc
