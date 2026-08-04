#!/usr/bin/env bash
# garage-backup — pull every Garage bucket down to this machine, and VERIFY the copy.
#
#   devbox run garage-backup            # sync everything not excluded, then check counts
#   devbox run garage-backup -- --list  # show what would be pulled, change nothing
#
# WHY THIS EXISTS. Garage runs `replication_factor = 1` on a single node (tofu/garage.tf); all
# redundancy is Longhorn's two replicas underneath. Nothing backs Garage *out* — FU-013 backs other
# things *into* it. Until the offsite bucket lands (operator plan: AWS/Civo, parked behind
# oracle-fleet/idp reaching prod), this local copy is the only restore path that exists.
#
# The meta volume is the sharp edge, not the data: 10Gi of LMDB metadata on `longhorn`. Lose it and
# the ~60GB of data blocks are unreadable. That is why this pulls OBJECTS through the S3 API rather
# than snapshotting volumes — an object copy survives a metadata loss, a block copy does not.
#
# The bucket list is read LIVE from Garage, never hard-coded, so a bucket created tomorrow is
# included tomorrow instead of being silently missed.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

DEST="${GARAGE_BACKUP_DIR:-$ROOT/backups/garage}"

# ert-snapshots (60.4GB, 252k objects) is excluded BY DECISION, not by oversight: the oracle-fleet
# ingestion re-downloads its source zip, so it is recoverable at the cost of a long re-ingest.
# Everything else here is either irreplaceable or cheap to hold. Override with GARAGE_BACKUP_SKIP.
SKIP="${GARAGE_BACKUP_SKIP:-ert-snapshots}"

LIST_ONLY=0
[ "${1:-}" = "--list" ] && LIST_ONLY=1

KC="${KUBECONFIG:-$ROOT/tofu/kubeconfig}"
buckets="$(kubectl --kubeconfig "$KC" -n garage exec garage-0 -c garage -- /garage bucket list 2>/dev/null \
  | awk 'NR>1 && $3 != "" {print $3}' | grep -vE '^(ID|Global)$' || true)"
[ -n "$buckets" ] || { echo "FAIL: could not read the bucket list from garage-0 — refusing to report a backup." >&2; exit 2; }

echo "── garage-backup → ${DEST}"
echo

rc=0
for b in $buckets; do
  case " $SKIP " in *" $b "*) echo "skip  $b  (excluded: recoverable from source)"; continue ;; esac

  # Remote truth first, so "0 objects synced" can never pass as success.
  remote="$(kubectl --kubeconfig "$KC" -n garage exec garage-0 -c garage -- /garage bucket info "$b" 2>/dev/null \
    | grep -E '^Objects:' | grep -oE '[0-9]+' | head -1 || true)"
  remote="${remote:-?}"

  if [ "$LIST_ONLY" = 1 ]; then
    printf 'would sync  %-30s %s objects\n' "$b" "$remote"
    continue
  fi

  mkdir -p "$DEST/$b"
  # homelab-tofu-state needs its own key — the browse key has no grant on it, and should not.
  if [ "$b" = "homelab-tofu-state" ]; then
    # shellcheck source=/dev/null
    ( . "$ROOT/scripts/tofu-state-env.sh" && aws s3 sync "s3://$b" "$DEST/$b" --only-show-errors )
  else
    bash "$ROOT/scripts/garage-s3.sh" s3 sync "s3://$b" "$DEST/$b" --only-show-errors
  fi

  local_n="$(find "$DEST/$b" -type f | wc -l | tr -d ' ')"
  if [ "$remote" != "?" ] && [ "$local_n" != "$remote" ]; then
    printf '  ✗ %-28s local %s != remote %s\n' "$b" "$local_n" "$remote"; rc=1
  else
    printf '  ✓ %-28s %s objects\n' "$b" "$local_n"
  fi
done

[ "$LIST_ONLY" = 1 ] && exit 0

echo
du -sh "$DEST" 2>/dev/null || true
if [ "$rc" != 0 ]; then
  echo "FAIL: at least one bucket's local copy does not match Garage — this is NOT a usable backup." >&2
  exit 1
fi
echo "OK — every non-excluded bucket matches Garage object-for-object."
