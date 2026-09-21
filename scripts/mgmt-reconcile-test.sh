#!/usr/bin/env bash
# mgmt-reconcile-test — the node reconciler's state machine (scripts/mgmt-reconcile.sh) against a
# FAKE verb and a FAKE live fleet: every transition the loop owns — idle, sync → idle, a gate's
# refusal (retried), a failure (PARKED, never retried on the same key), a new key un-parking, a
# zero-exit verb whose diff disagrees, a sync the loop died in, WIP 1 (windows, queueing), the
# control-plane guard, manual nodes untouched, and a diff that cannot be read. No cluster, no box.
#   devbox run mgmt-reconcile-test
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export RECONCILE_DIR="$T/state" MGMT_TEXTFILE_DIR="$T/text"
export RECONCILE_MACHINES_JSON="$T/machines.json" RECONCILE_TARGETS_JSON="$T/targets.json"
export RECONCILE_WINDOWS_JSON="$T/windows.json"
export RECONCILE_DIFF_CMD="bash $T/diff.sh" RECONCILE_VERB="bash $T/verb.sh"
export LIVE="$T/live.json" CALLS="$T/calls"
mkdir -p "$MGMT_TEXTFILE_DIR"

# live.json: node → {version, schematic} (absent = unreachable). The fake diff compares it with the
# targets file it is handed, in mgmt-probe.sh's NODE_DRIFT_OUT format.
cat >"$T/diff.sh" <<'EOF'
[ -f "${FAKE_DIFF_FAIL:-/nonexistent}" ] && exit 1
jq -r --slurpfile L "$LIVE" 'to_entries[] | .key as $n | .value as $d | ($L[0][$n]) as $l
  | if $l == null then "\($n) reachable\tdrift"
    else "\($n) reachable\tok",
         "\($n) version\t\(if $l.version == $d.version then "ok" else "drift" end)",
         "\($n) schematic\t\(if $l.schematic == $d.schematic then "ok" else "drift" end)" end' "$1" >"$2"
EOF
# The verb: records the call; FAKE_RC decides; on 0 it "installs" the declaration unless FAKE_NOOP.
cat >"$T/verb.sh" <<'EOF'
echo "$*" >>"$CALLS"
rc="${FAKE_RC:-0}"
if [ "$rc" = 0 ] && [ -z "${FAKE_NOOP:-}" ]; then
  jq --arg n "$2" --slurpfile D "$RECONCILE_TARGETS_JSON" '.[$n] = {version: $D[0][$n].version, schematic: $D[0][$n].schematic}' "$LIVE" >"$LIVE.t" && mv "$LIVE.t" "$LIVE"
fi
exit "$rc"
EOF

machines() { printf '{"machines":%s}' "$1" >"$RECONCILE_MACHINES_JSON"; }
targets()  { printf '%s' "$1" >"$RECONCILE_TARGETS_JSON"; }
live()     { printf '%s' "$1" >"$LIVE"; }
windows()  { printf '%s' "$1" >"$RECONCILE_WINDOWS_JSON"; }
reset()    { rm -rf "$RECONCILE_DIR" "$CALLS"; rm -f "$MGMT_TEXTFILE_DIR"/*; unset FAKE_RC FAKE_NOOP FAKE_DIFF_FAIL; windows '[]'; }
tick()     { bash "$HERE/mgmt-reconcile.sh" >"$T/out" 2>&1; echo $? >"$T/rc"; }
st()       { jq -r --arg n "$1" '.[$n].state // "none"' "$RECONCILE_DIR/state.json" 2>/dev/null || echo none; }
calls()    { [ -f "$CALLS" ] && grep -c . "$CALLS" || echo 0; }
metric()   { grep -F "$1" "$MGMT_TEXTFILE_DIR/mgmt_reconcile.prom" 2>/dev/null | awk '{print $NF}'; }

pass=0; fail=0
check() {  # <name> <condition...>
  local name="$1"; shift
  if "$@"; then pass=$((pass+1)); echo "PASS $name"
  else fail=$((fail+1)); echo "FAIL $name"; sed 's/^/     /' "$T/out"; fi
}

W='{"name":"wk-03","reconcile":"auto"}'; M='{"name":"wk-01"}'
D1='{"wk-03":{"version":"v1","schematic":"s","role":"worker"},"wk-01":{"version":"v1","schematic":"s","role":"worker"}}'
D2='{"wk-03":{"version":"v2","schematic":"s","role":"worker"},"wk-01":{"version":"v2","schematic":"s","role":"worker"}}'
D3='{"wk-03":{"version":"v3","schematic":"s","role":"worker"},"wk-01":{"version":"v3","schematic":"s","role":"worker"}}'
V1='{"wk-03":{"version":"v1","schematic":"s"},"wk-01":{"version":"v1","schematic":"s"}}'

# ── in sync ──
reset; machines "[$W,$M]"; targets "$D1"; live "$V1"; tick
check "in sync → idle, verb not called"      eval '[ "$(st wk-03)" = idle ] && [ "$(calls)" = 0 ] && [ "$(cat $T/rc)" = 0 ]'
check "metrics: idle=1, syncing=0, started=0, last-run stamped" eval '[ "$(metric "node=\"wk-03\",state=\"idle\"")" = 1 ] && [ "$(metric "node=\"wk-03\",state=\"syncing\"")" = 0 ] && [ "$(metric "sync_started_timestamp_seconds{node=\"wk-03\"}")" = 0 ] && [ -n "$(metric mgmt_reconcile_last_run_timestamp_seconds)" ]'
check "a manual node publishes no state"     eval '[ "$(st wk-01)" = none ] && ! grep -q "wk-01" "$MGMT_TEXTFILE_DIR/mgmt_reconcile.prom"'

# ── a diff → one sync → idle; the manual node's identical diff is left alone ──
targets "$D2"; tick
check "diff → verb once on wk-03 only → idle" eval '[ "$(st wk-03)" = idle ] && [ "$(calls)" = 1 ] && [ "$(cat $CALLS)" = "upgrade wk-03" ] && [ "$(st wk-01)" = none ]'
tick
check "the next tick is a no-op"              eval '[ "$(calls)" = 1 ] && [ "$(st wk-03)" = idle ]'

# ── a refusal (exit 2) is retried; a failure (exit 1) parks and is NOT retried on the key ──
targets "$D3"; FAKE_RC=2 tick
check "verb exit 2 → pending (refused, nothing touched)" eval '[ "$(st wk-03)" = pending ] && [ "$(calls)" = 2 ]'
FAKE_RC=1 tick
check "retried next tick; exit 1 → PARKED"   eval '[ "$(st wk-03)" = parked ] && [ "$(calls)" = 3 ] && [ "$(metric "node=\"wk-03\",state=\"parked\"")" = 1 ]'
FAKE_RC=0 tick; FAKE_RC=0 tick
check "parked on the same key: never retried" eval '[ "$(st wk-03)" = parked ] && [ "$(calls)" = 3 ]'
targets "$D1"; live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"   # a NEW key (still a diff: live v2)
tick
check "a new declared key un-parks → synced"  eval '[ "$(st wk-03)" = idle ] && [ "$(calls)" = 4 ]'

# ── the diff reaching zero by other means clears a park ──
reset; machines "[$W]"; targets "$D2"; live "$V1"; FAKE_RC=1 tick
live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"; tick
check "park cleared when the diff is zero (fixed by hand)" eval '[ "$(st wk-03)" = idle ] && [ "$(calls)" = 1 ]'

# ── the verb says done, the diff disagrees → parked ──
reset; machines "[$W]"; targets "$D2"; live "$V1"; FAKE_NOOP=1 tick
check "exit 0 with the diff still non-zero → PARKED" eval '[ "$(st wk-03)" = parked ] && grep -q "diff is not zero" "$RECONCILE_DIR/state.json"'

# ── a sync the loop died in ──
reset; machines "[$W]"; targets "$D2"; live "$V1"; mkdir -p "$RECONCILE_DIR"
echo '{"wk-03":{"state":"syncing","key":"v2/s","since":1}}' >"$RECONCILE_DIR/state.json"; tick
check "found mid-sync → PARKED interrupted, verb not re-run" eval '[ "$(st wk-03)" = parked ] && [ "$(calls)" = 0 ] && grep -q interrupted "$RECONCILE_DIR/state.json"'

# ── WIP 1 ──
reset; machines "[$W]"; targets "$D2"; live "$V1"; windows '[{"id":"m70s-1","node":"m70s","by":"seat"}]'; tick
check "a live window on another node → pending, verb not run" eval '[ "$(st wk-03)" = pending ] && [ "$(calls)" = 0 ]'
windows '[{"id":"seat-1","node":"","by":"seat"}]'; tick
check "a node-less (seat-wide) window also refuses" eval '[ "$(st wk-03)" = pending ] && [ "$(calls)" = 0 ]'
windows '[{"id":"wk-03-1","node":"wk-03","by":"seat"}]'; tick
check "a window on the target itself is the same window → synced" eval '[ "$(st wk-03)" = idle ] && [ "$(calls)" = 1 ]'
reset; machines "[$W,{\"name\":\"wk-01\",\"reconcile\":\"auto\"}]"; targets "$D2"; live "$V1"; tick
check "two diffs → ONE sync per tick, the other queued" eval '[ "$(calls)" = 1 ] && [ "$(st wk-03)" = idle ] && [ "$(st wk-01)" = pending ] && grep -q "queued behind wk-03" "$RECONCILE_DIR/state.json"'
tick
check "…and the queued one goes on the next tick" eval '[ "$(calls)" = 2 ] && [ "$(st wk-01)" = idle ] && [ "$(tail -1 $CALLS)" = "upgrade wk-01" ]'

# ── guards ──
reset; machines '[{"name":"cp-01","reconcile":"auto"}]'; targets '{"cp-01":{"version":"v2","schematic":"s","role":"controlplane"}}'
live '{"cp-01":{"version":"v1","schematic":"s"}}'; tick
check "a declared control plane is never synced" eval '[ "$(st cp-01)" = parked ] && [ "$(calls)" = 0 ]'
reset; machines "[$W]"; targets "$D2"; live '{}'; tick
check "an unreachable node → no action"      eval '[ "$(calls)" = 0 ] && [ "$(st wk-03)" = idle ]'
reset; machines "[$W]"; targets "$D2"; live "$V1"; touch "$T/fail"; FAKE_DIFF_FAIL="$T/fail" tick
check "an unreadable diff → exit 1, nothing run, last-run not stamped" eval '[ "$(cat $T/rc)" = 1 ] && [ "$(calls)" = 0 ] && [ ! -f "$RECONCILE_DIR/last-run" ]'
reset; machines "[$W]"; targets "$D2"; live "$V1"; tick
machines "[$M]"; tick
check "a node leaving auto leaves the state + metrics" eval '[ "$(st wk-03)" = none ] && ! grep -q "wk-03" "$MGMT_TEXTFILE_DIR/mgmt_reconcile.prom"'

echo "mgmt-reconcile-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
