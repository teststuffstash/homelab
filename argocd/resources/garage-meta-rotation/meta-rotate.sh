#!/bin/sh
# meta-rotate — the rotation loop's SEED step, run as an init container in every garage pod
# (argocd/platform/garage.yaml extraInitContainers). docs/garage.md §Metadata reclamation.
#
# No-op unless the controller has named THIS pod with a generation it has not applied yet
# (ConfigMap garage-meta-rotation-state → env ROTATE_TARGET / ROTATE_GENERATION). Then: replace
# the live LMDB env with this pod's latest FINISHED compacted snapshot (Garage's own 6h
# auto-snapshot, metadata_snapshots_dir on the data volume) and let Garage reconcile the ≤6h
# delta from its two peers. Node identity (node_key*) and the layout files are untouched, so no
# layout change follows. Every outcome is one greppable line: ROTATED / SKIP / ROTATE-FAIL / idle
# — the controller reads it from the init container's log.
#
# Why "finished" needs a test: a snapshot in progress has the same name shape as a finished one,
# and a pod deleted mid-snapshot leaves a truncated file (the 2026-09-07 20:21Z one, 2.3 GB of
# 4.1 — a corrupt seed). Two checks, both cheap: the file was last written ≥ MIN_AGE ago, and it
# is ≥ 90 % of the largest snapshot present. Never `set -e`: a refusal must still start Garage.
set -u
M=/mnt/meta; SNAPS=/mnt/data/meta_snapshots
POD="${POD_NAME:-$(hostname)}"
TARGET="${ROTATE_TARGET:-}"; GEN="${ROTATE_GENERATION:-0}"
MIN_AGE="${ROTATE_SNAPSHOT_MIN_AGE_S:-600}"
log() { echo "meta-rotate: $*"; }

if [ -z "$TARGET" ] || [ "$TARGET" != "$POD" ]; then
  log "idle pod=$POD target='$TARGET' gen=$GEN"; exit 0
fi
applied="$(cat "$M/.meta-rotation-gen" 2>/dev/null || echo 0)"
if [ "$applied" = "$GEN" ]; then log "idle pod=$POD gen=$GEN already applied"; exit 0; fi
live="$M/db.lmdb/data.mdb"
if [ ! -f "$live" ]; then log "SKIP gen=$GEN reason=no-live-env"; echo "$GEN" > "$M/.meta-rotation-gen"; exit 0; fi

now=$(date +%s); best=""; best_sz=0; max_sz=0
for f in $(ls -1d "$SNAPS"/*/db.lmdb 2>/dev/null | sort -r); do
  sz=$(stat -c %s "$f"); [ "$sz" -gt "$max_sz" ] && max_sz=$sz
done
for f in $(ls -1d "$SNAPS"/*/db.lmdb 2>/dev/null | sort -r); do
  sz=$(stat -c %s "$f"); mt=$(stat -c %Y "$f"); age=$((now - mt))
  if [ "$age" -lt "$MIN_AGE" ]; then log "candidate $f: written ${age}s ago (<${MIN_AGE}s) — possibly torn, skipped"; continue; fi
  if [ $((sz * 10)) -lt $((max_sz * 9)) ]; then log "candidate $f: ${sz}B < 90% of the largest (${max_sz}B) — torn, skipped"; continue; fi
  best="$f"; best_sz=$sz; break
done
if [ -z "$best" ]; then log "SKIP gen=$GEN reason=no-finished-snapshot"; echo "$GEN" > "$M/.meta-rotation-gen"; exit 0; fi

old_sz=$(stat -c %s "$live")
avail=$(( $(df -Pk "$M" | awk 'NR==2 {print $4}') * 1024 ))
need=$((best_sz + best_sz / 10))
if [ "$avail" -ge "$need" ]; then mode=copy-then-drop
elif [ $((avail + old_sz)) -ge "$need" ]; then mode=drop-then-copy
else log "SKIP gen=$GEN reason=no-space avail=$avail old=$old_sz need=$need"; echo "$GEN" > "$M/.meta-rotation-gen"; exit 0; fi

log "ROTATING gen=$GEN pod=$POD from=$best snapshot_bytes=$best_sz live_bytes=$old_sz mode=$mode"
t0=$(date +%s)
if ! mv "$M/db.lmdb" "$M/db.lmdb.rotating"; then log "ROTATE-FAIL gen=$GEN reason=mv"; echo "$GEN" > "$M/.meta-rotation-gen"; exit 0; fi
[ "$mode" = drop-then-copy ] && rm -rf "$M/db.lmdb.rotating"
if mkdir "$M/db.lmdb" && cp "$best" "$M/db.lmdb/data.mdb"; then
  rm -rf "$M/db.lmdb.rotating"
  echo "$GEN" > "$M/.meta-rotation-gen"
  log "ROTATED gen=$GEN pod=$POD from=$best old_bytes=$old_sz new_bytes=$(stat -c %s "$M/db.lmdb/data.mdb") seconds=$(( $(date +%s) - t0 ))"
else
  rm -rf "$M/db.lmdb"
  if [ -d "$M/db.lmdb.rotating" ]; then
    mv "$M/db.lmdb.rotating" "$M/db.lmdb"
    log "ROTATE-FAIL gen=$GEN reason=copy live-env-restored"
  else
    mkdir -p "$M/db.lmdb"
    log "ROTATE-FAIL gen=$GEN reason=copy live-env-LOST — Garage starts with empty tables and resyncs natively from its peers (ADR-114's corrupt-node primitive; GarageTableEmpty will fire)"
  fi
  echo "$GEN" > "$M/.meta-rotation-gen"
fi
exit 0
