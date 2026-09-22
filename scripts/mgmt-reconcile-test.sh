#!/usr/bin/env bash
# mgmt-reconcile-test — the node reconciler's state machine (scripts/mgmt-reconcile.sh) against a
# FAKE verb and a FAKE live fleet: every transition the loop owns — idle, sync → idle, a gate's
# refusal (retried), a failure (PARKED, never retried on the same key), a new key un-parking, a
# zero-exit verb whose diff disagrees, a sync the loop died in, WIP 1 (windows, queueing), the
# control-plane guard, manual nodes untouched, and a diff that cannot be read — run twice, with no
# switch and with the rollout switch explicitly OFF. Then the FLEET ROLLOUT (switch ON, FU-273)
# against a fake CP verb, ranking, evidence script, Prometheus and kubectl: canaries per type, the
# evidence wait and its timeout, CPs last, halt/resume, the pressure taints, supersede, revert, and
# the switch going off mid-rollout. No cluster, no box.
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
# FAKE_INSTALLED=1: it installs and THEN fails (nx-01, 2026-09-22 — back on the target, a post-check
# failed). FAKE_LEAVE_WINDOW=1: a failure leaves its own declared window open, as the real verb does.
cat >"$T/verb.sh" <<'EOF'
echo "$*" >>"$CALLS"
rc="${FAKE_RC:-0}"
if { [ "$rc" = 0 ] && [ -z "${FAKE_NOOP:-}" ]; } || [ -n "${FAKE_INSTALLED:-}" ]; then
  jq --arg n "$2" --slurpfile D "$RECONCILE_TARGETS_JSON" '.[$n] = {version: $D[0][$n].version, schematic: $D[0][$n].schematic}' "$LIVE" >"$LIVE.t" && mv "$LIVE.t" "$LIVE"
fi
if [ "$rc" != 0 ] && [ -n "${FAKE_LEAVE_WINDOW:-}" ]; then
  jq -c --arg n "$2" '. + [{id: ("nm-" + $n), node: $n, by: "node-maintenance.sh"}]' "$RECONCILE_WINDOWS_JSON" >"$RECONCILE_WINDOWS_JSON.t" \
    && mv "$RECONCILE_WINDOWS_JSON.t" "$RECONCILE_WINDOWS_JSON"
fi
[ -n "${FAKE_WH_AFTER:-}" ] && cp "$FAKE_WH_AFTER" "$WH_FILE"
exit "$rc"
EOF
# The read-only health check (node-maintenance.sh verify): FAKE_VERIFY_RC decides, every call recorded.
# The window close (node-maintenance.sh silence-close): drops only the verb's own records.
export RECONCILE_VERIFY="bash $T/verify.sh" RECONCILE_WINDOW_CLOSE="bash $T/wclose.sh" VCALLS="$T/vcalls" WCALLS="$T/wcalls"
cat >"$T/verify.sh" <<'EOF'
echo "$1" >>"$VCALLS"
exit "${FAKE_VERIFY_RC:-0}"
EOF
cat >"$T/wclose.sh" <<'EOF'
echo "$1" >>"$WCALLS"
jq -c --arg n "$1" 'map(select(.node != $n or .by != "node-maintenance.sh"))' "$RECONCILE_WINDOWS_JSON" >"$RECONCILE_WINDOWS_JSON.t" \
  && mv "$RECONCILE_WINDOWS_JSON.t" "$RECONCILE_WINDOWS_JSON"
EOF
# kubectl (the rollout's pressure taints; set for EVERY case, so the switch-off suite can assert it
# is never called): `get nodes -o json` from $TAINTS ({node: [taint]}), `taint node <n> k=v:e
# --overwrite`, `taint node <n> k:e-`, `taint node <n> k-`. Every call recorded in $KCALLS.
export RECONCILE_KUBECTL="bash $T/kubectl.sh" TAINTS="$T/taints.json" KCALLS="$T/kcalls"
echo '{}' >"$TAINTS"
cat >"$T/kubectl.sh" <<'EOF'
echo "$*" >>"$KCALLS"
case "$1 $2" in
  "get nodes") jq '{items: (to_entries | map({metadata: {name: .key}, spec: {taints: .value}}))}' "$TAINTS" ;;
  "taint node")
    n="$3"; spec="$4"
    if [ "${spec%-}" != "$spec" ]; then
      s="${spec%-}"; k="${s%%:*}"; e=""; [ "$k" != "$s" ] && e="${s#*:}"
      jq --arg n "$n" --arg k "$k" --arg e "$e" '.[$n] |= map(select(.key != $k or ($e != "" and .effect != $e)))' "$TAINTS" >"$TAINTS.t"
    else
      kv="${spec%%:*}"; e="${spec#*:}"; k="${kv%%=*}"; v="${kv#*=}"
      jq --arg n "$n" --arg k "$k" --arg v "$v" --arg e "$e" '.[$n] = ([.[$n][]? | select(.key != $k or .effect != $e)] + [{key: $k, value: $v, effect: $e}])' "$TAINTS" >"$TAINTS.t"
    fi
    mv "$TAINTS.t" "$TAINTS" ;;
  *) exit 1 ;;
esac
EOF

# SWITCH: extra top-level JSON (the reconcile_rollout block) — empty = the pre-rollout inventory.
machines() { printf '{%s"machines":%s}' "${SWITCH:+$SWITCH,}" "$1" >"$RECONCILE_MACHINES_JSON"; }
targets()  { printf '%s' "$1" >"$RECONCILE_TARGETS_JSON"; }
live()     { printf '%s' "$1" >"$LIVE"; }
windows()  { printf '%s' "$1" >"$RECONCILE_WINDOWS_JSON"; }
reset()    { rm -rf "$RECONCILE_DIR" "$CALLS" "$KCALLS" "$VCALLS" "$WCALLS"; rm -f "$MGMT_TEXTFILE_DIR"/*
             unset FAKE_RC FAKE_NOOP FAKE_DIFF_FAIL FAKE_INSTALLED FAKE_LEAVE_WINDOW FAKE_VERIFY_RC; windows '[]'; }
cause()    { jq -r --arg n "$1" '.[$n].cause // ""' "$RECONCILE_DIR/state.json" 2>/dev/null; }
vcalls()   { [ -f "$VCALLS" ] && grep -c . "$VCALLS" || echo 0; }
tick()     { bash "$HERE/mgmt-reconcile.sh" >"$T/out" 2>&1; echo $? >"$T/rc"; }
st()       { jq -r --arg n "$1" '.[$n].state // "none"' "$RECONCILE_DIR/state.json" 2>/dev/null || echo none; }
calls()    { [ -f "$CALLS" ] && grep -c . "$CALLS" || echo 0; }
lastcall_legacy() { tail -1 "$CALLS" 2>/dev/null; }
metric()   { grep -v '^#' "$MGMT_TEXTFILE_DIR/mgmt_reconcile.prom" 2>/dev/null | grep -F "$1" | awk '{print $NF}'; }

pass=0; fail=0
check() {  # <name> <condition...>
  local name="$1${SUFFIX:-}"; shift
  if "$@"; then pass=$((pass+1)); echo "PASS $name"
  else fail=$((fail+1)); echo "FAIL $name"; sed 's/^/     /' "$T/out"; fi
}

W='{"name":"wk-03","reconcile":"auto"}'; M='{"name":"wk-01"}'
D1='{"wk-03":{"version":"v1","schematic":"s","role":"worker"},"wk-01":{"version":"v1","schematic":"s","role":"worker"}}'
D2='{"wk-03":{"version":"v2","schematic":"s","role":"worker"},"wk-01":{"version":"v2","schematic":"s","role":"worker"}}'
D3='{"wk-03":{"version":"v3","schematic":"s","role":"worker"},"wk-01":{"version":"v3","schematic":"s","role":"worker"}}'
V1='{"wk-03":{"version":"v1","schematic":"s"},"wk-01":{"version":"v1","schematic":"s"}}'

# ── the pre-rollout suite, run twice — no switch key, and the switch explicitly OFF — so the
# switch-off path is pinned to the old behaviour on every one of its cases ──
legacy_suite() {
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

# ── an impossible path (verb exit 4: downgrade / skipped minor) parks at once, never retried ──
reset; machines "[$W]"; targets "$D1"; live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"; FAKE_RC=4 tick
check "verb exit 4 → PARKED (impossible path), not pending" eval '[ "$(st wk-03)" = parked ] && [ "$(calls)" = 1 ] && grep -q "impossible" "$RECONCILE_DIR/state.json"'
FAKE_RC=4 tick
check "…and not retried on the same key" eval '[ "$(calls)" = 1 ]'

# ── the diff reaching zero by other means clears a FAILED-VERB park only with the health check ──
reset; machines "[$W]"; targets "$D2"; live "$V1"; FAKE_RC=1 tick
live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"; tick
check "park cleared when the diff is zero (fixed by hand) AND verify passes" eval '[ "$(st wk-03)" = idle ] && [ "$(calls)" = 1 ] && [ "$(vcalls)" = 1 ]'

# ── FU-276 (a): verb exits 1 AFTER installing (nx-01) → diff zero at once; health decides ──
reset; machines "[$W]"; targets "$D2"; live "$V1"; FAKE_RC=1 FAKE_INSTALLED=1 tick
check "verb exit 1 after the install → PARKED, cause verb-failed" eval '[ "$(st wk-03)" = parked ] && [ "$(cause wk-03)" = verb-failed ]'
FAKE_VERIFY_RC=1 tick
check "diff zero + verify FAILS → still PARKED, verify asked, not counted in sync" eval '[ "$(st wk-03)" = parked ] && [ "$(vcalls)" = 1 ] && [ "$(calls)" = 1 ] && grep -q "health check failing" "$RECONCILE_DIR/state.json" && grep -q "stays PARKED, not counted synced" "$T/out"'
FAKE_VERIFY_RC=1 tick
check "…re-checked every tick, never re-synced, cause kept" eval '[ "$(st wk-03)" = parked ] && [ "$(vcalls)" = 2 ] && [ "$(calls)" = 1 ] && [ "$(cause wk-03)" = verb-failed ]'
tick
check "verify passes → cleared to idle" eval '[ "$(st wk-03)" = idle ] && [ "$(vcalls)" = 3 ] && [ "$(cause wk-03)" = "" ]'
# a park from before causes existed: read from its reason, never cleared on the diff alone
reset; machines "[$W]"; targets "$D2"; live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"; mkdir -p "$RECONCILE_DIR"
echo '{"wk-03":{"state":"parked","key":"v2/s","since":1,"reason":"verb exited 1 — the one attempt for this key is spent; read the journal, then clear the state"}}' >"$RECONCILE_DIR/state.json"
FAKE_VERIFY_RC=1 tick
check "a pre-FU-276 'verb exited' park (no cause field) is treated as verb-failed" eval '[ "$(st wk-03)" = parked ] && [ "$(vcalls)" = 1 ]'
reset; machines "[$W]"; targets "$D2"; live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"; mkdir -p "$RECONCILE_DIR"
echo '{"wk-03":{"state":"parked","key":"v2/s","since":1,"reason":"verb exited 0 but the diff is not zero (version=drift schematic=ok)"}}' >"$RECONCILE_DIR/state.json"
FAKE_VERIFY_RC=1 tick
check "a pre-FU-276 'verb exited 0 but the diff…' park is diff-disagrees: clears on diff zero, no verify" eval '[ "$(st wk-03)" = idle ] && [ "$(vcalls)" = 0 ]'

# ── the exit-0-but-diff-non-zero park still clears on diff zero, without the health check ──
reset; machines "[$W]"; targets "$D2"; live "$V1"; FAKE_NOOP=1 tick
live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"; FAKE_VERIFY_RC=1 tick
check "diff-disagrees park → cleared on diff zero, verify never asked" eval '[ "$(st wk-03)" = idle ] && [ "$(vcalls)" = 0 ]'

# ── an interrupted sync: the same health rule, and its window closed at park time ──
reset; machines "[$W]"; targets "$D2"; live "$(jq -c '.["wk-03"].version = "v2"' <<<"$V1")"; mkdir -p "$RECONCILE_DIR"
windows '[{"id":"nm-wk-03","node":"wk-03","by":"node-maintenance.sh"}]'
echo '{"wk-03":{"state":"syncing","key":"v2/s","since":1}}' >"$RECONCILE_DIR/state.json"; FAKE_VERIFY_RC=1 tick
check "interrupted + diff zero + verify fails → PARKED interrupted, its window closed" eval '[ "$(st wk-03)" = parked ] && [ "$(cause wk-03)" = interrupted ] && [ "$(cat $WCALLS)" = wk-03 ] && [ "$(cat $RECONCILE_WINDOWS_JSON)" = "[]" ]'

# ── FU-276 (b): the failed verb's own window is closed at park time, so the next tick is not refused ──
reset; machines "[$W]"; targets "$D2"; live "$V1"
windows '[{"id":"seat-wk-03","node":"wk-03","by":"seat","admit_reconciler":true}]'
FAKE_RC=1 FAKE_LEAVE_WINDOW=1 tick
check "verb exit 1 → PARKED, ITS window (--by node-maintenance.sh) closed, the seat's admitting record untouched" eval '[ "$(st wk-03)" = parked ] && [ "$(cat $WCALLS)" = wk-03 ] && [ "$(jq -c "map(.id)" $RECONCILE_WINDOWS_JSON)" = "[\"seat-wk-03\"]" ]'
reset; machines "[$W,{\"name\":\"wk-01\",\"reconcile\":\"auto\"}]"; targets "$D2"; live "$V1"
FAKE_RC=1 FAKE_LEAVE_WINDOW=1 tick
check "two diffs: wk-03's verb exits 1 → parked, its window closed" eval '[ "$(st wk-03)" = parked ] && [ "$(cat $RECONCILE_WINDOWS_JSON)" = "[]" ]'
tick
check "…the next tick syncs the queued node — not refused by the parked node's window" eval '[ "$(lastcall_legacy)" = "upgrade wk-01" ] && [ "$(st wk-01)" = idle ] && [ "$(st wk-03)" = parked ]'
reset; machines "[$W]"; targets "$D2"; live "$V1"; FAKE_RC=2 FAKE_LEAVE_WINDOW=1 tick
check "a refusal (exit 2) closes nothing (the verb closed its own)" eval '[ ! -f "$WCALLS" ] && [ "$(st wk-03)" = pending ]'

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
check "a seat's window on the TARGET refuses too (hands-on work, no sync on top)" eval '[ "$(st wk-03)" = pending ] && [ "$(calls)" = 0 ] && grep -q "wk-03-1" "$RECONCILE_DIR/state.json"'
windows '[{"id":"wk-03-1","node":"wk-03","by":"seat","admit_reconciler":false}]'; tick
check "admit_reconciler:false is the same refusal" eval '[ "$(st wk-03)" = pending ] && [ "$(calls)" = 0 ]'
windows '[{"id":"m70s-1","node":"m70s","by":"seat","admit_reconciler":true}]'; tick
check "an admitting window on ANOTHER node still refuses" eval '[ "$(st wk-03)" = pending ] && [ "$(calls)" = 0 ]'
windows '[{"id":"wk-03-1","node":"wk-03","by":"seat","admit_reconciler":true}]'; tick
check "a window on the target opened with --admit-reconciler → synced (the attended canary)" eval '[ "$(st wk-03)" = idle ] && [ "$(calls)" = 1 ]'
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
check "switch off: no rollout record, no rollout series, kubectl never called" eval '[ ! -f "$RECONCILE_DIR/rollout.json" ] && ! grep -q mgmt_reconcile_rollout "$MGMT_TEXTFILE_DIR/mgmt_reconcile.prom" && [ ! -s "$KCALLS" ]'
}
SUFFIX="" SWITCH="" legacy_suite
SUFFIX=" [switch off]" SWITCH='"reconcile_rollout":{"enabled":false}' legacy_suite
unset SUFFIX SWITCH

# ═══ THE FLEET ROLLOUT (switch ON, FU-273) ═══════════════════════════════════════════════════════
# An eight-node fleet: four worker TYPES (class × role × schematic × storage) and two control planes.
# The fake ranking (node-maintenance.sh order's TSV) ranks them least-risky first:
#   wk-03 nx-01 wk-02 (compute) · wk-01 (vm, Longhorn replicas) · hp-01 m70s (metal, Garage zones) · cp-01 cp-02
# so the canaries are wk-03 (vm/L/compute), nx-01 (metal/K/compute), wk-01 (vm/L/storage),
# hp-01 (metal/M/storage); wk-02, m70s and the CPs are the fleet stage.
export RECONCILE_CP_VERB="bash $T/cpverb.sh" RECONCILE_ORDER_CMD="bash $T/order.sh"
export RECONCILE_EVIDENCE="$T/evidence.sh" RECONCILE_DIFFERENTIAL_CMD="bash $T/differential.sh"
export EVID="$T/evid"
cat >"$T/cpverb.sh" <<'EOF'
echo "cp $1" >>"$CALLS"
rc="${FAKE_CP_RC:-0}"
if [ "$rc" = 0 ]; then
  jq --arg n "$1" --slurpfile D "$RECONCILE_TARGETS_JSON" '.[$n] = {version: $D[0][$n].version, schematic: $D[0][$n].schematic}' "$LIVE" >"$LIVE.t" && mv "$LIVE.t" "$LIVE"
fi
[ -n "${FAKE_WH_AFTER:-}" ] && cp "$FAKE_WH_AFTER" "$WH_FILE"
exit "$rc"
EOF
cat >"$T/order.sh" <<'EOF'
[ -n "${FAKE_ORDER_FAIL:-}" ] && exit 2
printf '0\twk-03\tv\t0\t0\t-\t0\n0\tnx-01\tv\t0\t0\t-\t0\n0\twk-02\tv\t0\t0\t-\t0\n2\twk-01\tv\t0\t0\t-\t4\n5\thp-01\tv\t0\t0\tyes\t3\n5\tm70s\tv\t0\t0\tyes\t3\n20\tcp-01\tv\t0\t2\t-\t0\n20\tcp-02\tv\t0\t2\t-\t0\n'
EOF
# evidence: $EVID/<node> holds the exit code (absent = 1, not yet); every call is recorded.
cat >"$T/evidence.sh" <<'EOF'
echo "$1 $2" >>"$EVID/calls"
exit "$(cat "$EVID/$1" 2>/dev/null || echo 1)"
EOF
cat >"$T/differential.sh" <<'EOF'
[ -n "${FAKE_DIFFERENTIAL_UNREADABLE:-}" ] && exit 1
echo "${FAKE_DIFFERENTIAL:-0}"
EOF

# The workload read (node-maintenance.sh workload-health, FU-278): $WH_FILE's JSON lines, or unreadable.
export RECONCILE_WORKLOAD_HEALTH_CMD="bash $T/wh.sh" WH_FILE="$T/wh.jsonl"
cat >"$T/wh.sh" <<'EOF'
[ -n "${FAKE_WH_UNREADABLE:-}" ] && exit 1
cat "$WH_FILE"
EOF
wl()  { jq -nc --arg k "$1" --arg c "$2" --arg r "$3" --argjson h "$4" \
          '{key:$k, class:$c, revision:$r, healthy:$h, reason:(if $h then "" else "\($k | split("/")[2])-x: CrashLoopBackOff" end), since:(if $h then "" else "2026-09-22T12:47:06Z" end)}'; }
whf() { printf '%s\n' "$@" >"$WH_FILE"; }
FLEET="wk-03 nx-01 wk-02 wk-01 hp-01 m70s cp-01 cp-02"
ON='"reconcile_rollout":{"enabled":true}'
fleet_machines() { SWITCH="${1:-$ON}" machines "$(for n in $FLEET; do printf '{"name":"%s","reconcile":"auto"}\n' "$n"; done | jq -sc .)"; }
fleet_targets() {  # <version> [<node>=<version> …] — the declaration, with per-node overrides
  local v="$1"; shift
  targets "$(jq -nc --arg v "$v" --arg o "$*" '
    {"wk-03":  {class:"vm",    role:"worker",       schematic:"L", version:$v},
     "nx-01":  {class:"metal", role:"worker",       schematic:"K", version:$v},
     "wk-02":  {class:"vm",    role:"worker",       schematic:"L", version:$v},
     "wk-01":  {class:"vm",    role:"worker",       schematic:"L", version:$v},
     "hp-01":  {class:"metal", role:"worker",       schematic:"M", version:$v},
     "m70s":   {class:"metal", role:"worker",       schematic:"M", version:$v},
     "cp-01":  {class:"vm",    role:"controlplane", schematic:"P", version:$v},
     "cp-02":  {class:"vm",    role:"controlplane", schematic:"P", version:$v}}
    | reduce ($o | split(" ")[] | select(length > 0) | split("=")) as $p (.; .[$p[0]].version = $p[1])')"
}
fleet_live() {  # <version> [<node>=<version> …]
  local v="$1"; shift
  live "$(jq -nc --arg v "$v" --arg o "$*" '
    {"wk-03":"L","nx-01":"K","wk-02":"L","wk-01":"L","hp-01":"M","m70s":"M","cp-01":"P","cp-02":"P"}
    | map_values({version:$v, schematic:.})
    | reduce ($o | split(" ")[] | select(length > 0) | split("=")) as $p (.; .[$p[0]].version = $p[1])')"
}
# Every node starts with an unrelated taint the rollout must never touch.
fleet_taints() { jq -nc --arg f "$FLEET" '$f | split(" ") | map({key: ., value: [{key:"homelab.io/other", value:"x", effect:"NoSchedule"}]}) | from_entries' >"$TAINTS"; }
rreset() { reset; rm -rf "$EVID" "$KCALLS"; mkdir -p "$EVID"; fleet_taints
           unset FAKE_CP_RC FAKE_ORDER_FAIL FAKE_DIFFERENTIAL FAKE_DIFFERENTIAL_UNREADABLE RECONCILE_CANARY_TIMEOUT FAKE_WH_AFTER FAKE_WH_UNREADABLE
           rm -f "$RECONCILE_DIR/workload-health.ack"; whf "$(wl kube-system/Deployment/coredns platform r1 true)"; }
ro()      { jq -r "$1" "$RECONCILE_DIR/rollout.json" 2>/dev/null; }
behind()  { jq -r --arg n "$1" '[.[$n][]? | select(.key == "homelab.io/talos-behind") | .value] | join(",")' "$TAINTS"; }
other_taints_intact() { [ "$(jq '[.[][] | select(.key == "homelab.io/other")] | length' "$TAINTS")" = 8 ]; }
lastcall() { tail -1 "$CALLS" 2>/dev/null; }

# ── the pilot: switch OFF with every node auto → only the pilot moves, exactly as before ──
rreset; fleet_machines '"reconcile_rollout":{"enabled":false,"pilot":["wk-03"]}'; fleet_targets v2; fleet_live v1; tick
check "switch off + pilot: only the pilot syncs; nothing else gets state" eval '[ "$(calls)" = 1 ] && [ "$(lastcall)" = "upgrade wk-03" ] && [ "$(st nx-01)" = none ] && [ "$(st cp-01)" = none ]'
check "switch off + pilot: no rollout, no taints, kubectl never called" eval '[ ! -f "$RECONCILE_DIR/rollout.json" ] && [ ! -s "$KCALLS" ] && [ -z "$(behind nx-01)" ]'

# ── start: canary stage, one canary per type, least risky first; the pressure on everyone else ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1; tick
check "rollout starts at canary; the first canary is the least risky node (wk-03)" eval '[ "$(ro .target)" = v2 ] && [ "$(ro .stage)" = canary ] && [ "$(lastcall)" = "upgrade wk-03" ] && [ "$(st wk-03)" = idle ]'
check "one canary per TYPE: wk-03 nx-01 wk-01 hp-01 (no CP, no second of a type)" eval '[ "$(ro "[.canaries[]] | sort | join(\" \")")" = "hp-01 nx-01 wk-01 wk-03" ]'
check "pressure: every not-yet node tainted talos-behind=v2, the synced canary not" eval '[ "$(behind nx-01)" = v2 ] && [ "$(behind cp-02)" = v2 ] && [ "$(behind m70s)" = v2 ] && [ -z "$(behind wk-03)" ] && other_taints_intact'
check "the rest wait behind the canary" eval '[ "$(st wk-02)" = pending ] && grep -q "queued behind the canary" "$RECONCILE_DIR/state.json"'
check "metrics: stage canary=1, started stamped, per-node synced" eval '[ "$(metric "stage{target=\"v2\",kind=\"forward\",stage=\"canary\"}")" = 1 ] && [ "$(metric "rollout_started_timestamp_seconds{target=\"v2\"}")" -gt 0 ] && [ -n "$(metric "node_synced_timestamp_seconds{node=\"wk-03\",target=\"v2\"}")" ]'
tick; tick; tick
check "canaries synced one per tick, in rank order" eval '[ "$(sed -n 2,4p $CALLS | tr "\n" " ")" = "upgrade nx-01 upgrade wk-01 upgrade hp-01 " ] && [ -z "$(behind hp-01)" ]'
tick
check "all canaries synced, no evidence yet → no sync, the stage waits" eval '[ "$(calls)" = 4 ] && [ "$(ro .stage)" = canary ] && grep -q "waiting for evidence" "$RECONCILE_DIR/state.json" && [ "$(metric canary_wait_started_timestamp_seconds)" -gt 0 ]'
check "evidence asked per canary with its own sync time as <since>" eval '[ "$(awk "\$1==\"nx-01\"{print \$2; exit}" $EVID/calls)" = "$(ro ".nodes[\"nx-01\"].synced_at")" ]'
echo 0 >"$EVID/wk-03"; echo 0 >"$EVID/nx-01"; echo 2 >"$EVID/wk-01"; tick
check "evidence for three of four (2 = cannot tell = not yet) → still waiting" eval '[ "$(calls)" = 4 ] && [ "$(ro .stage)" = canary ] && [ "$(metric "canary_exercised{node=\"wk-03\"")" = 1 ] && [ "$(metric "canary_exercised{node=\"wk-01\"")" = 0 ]'
check "an exercised canary is not asked again" eval '[ "$(grep -c "^wk-03 " $EVID/calls)" = 2 ]'
echo 0 >"$EVID/wk-01"; echo 0 >"$EVID/hp-01"; tick
check "evidence for every canary → fleet stage, the next ranked node (wk-02) syncs the same tick" eval '[ "$(ro .stage)" = fleet ] && [ "$(lastcall)" = "upgrade wk-02" ] && [ "$(ro .canary_timed_out)" = false ]'
check "control planes wait while a worker is left" eval '[ "$(st cp-01)" = pending ] && grep -q "control planes go last" "$RECONCILE_DIR/state.json"'

# ── the halt: MgmtRolloutDifferential firing → no sync, pressure lifted; it resumes when it clears ──
FAKE_DIFFERENTIAL=1 tick
check "differential firing → HALTED, no sync, the pressure lifted" eval '[ "$(ro .stage)" = halted ] && [ "$(calls)" = 5 ] && [ -z "$(behind m70s)" ] && [ "$(metric "halted{reason=\"differential\"}")" = 1 ] && other_taints_intact'
FAKE_DIFFERENTIAL_UNREADABLE=1 tick
check "the differential unreadable → still halted (an unreadable gate is a no)" eval '[ "$(ro .stage)" = halted ] && [ "$(ro .halt_reason)" = unreadable ] && [ "$(calls)" = 5 ]'
tick
check "cleared → resumes the fleet stage: m70s syncs, pressure back on the rest" eval '[ "$(ro .stage)" = fleet ] && [ "$(lastcall)" = "upgrade m70s" ] && [ "$(behind cp-01)" = v2 ] && [ "$(metric "halted{reason=\"differential\"}")" = 0 ]'

# ── control planes: last, one at a time, through the CP verb ──
tick
check "no worker left → the first control plane, through controlplane-upgrade.sh" eval '[ "$(lastcall)" = "cp cp-01" ] && [ "$(st cp-01)" = idle ] && [ "$(st cp-02)" = pending ]'
FAKE_CP_RC=2 tick
check "the CP verb refusing (exit 2) → pending, retried" eval '[ "$(lastcall)" = "cp cp-02" ] && [ "$(st cp-02)" = pending ]'
tick
check "…then synced" eval '[ "$(st cp-02)" = idle ] && [ "$(calls)" = 9 ]'
tick
check "nothing left → rollout DONE, every talos-behind taint gone, nothing else touched" eval '[ "$(ro .stage)" = done ] && [ "$(calls)" = 9 ] && [ -z "$(jq -r "[.[][] | select(.key == \"homelab.io/talos-behind\")] | length | select(. > 0)" $TAINTS)" ] && other_taints_intact && [ "$(metric "stage{target=\"v2\",kind=\"forward\",stage=\"done\"}")" = 1 ]'

# ── the canary timeout: default forward, and the state says so ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1; tick; tick; tick; tick; tick
check "canaries synced, no evidence → waiting" eval '[ "$(ro .stage)" = canary ] && [ "$(calls)" = 4 ]'
RECONCILE_CANARY_TIMEOUT=0 tick
check "timeout → advance ANYWAY (wk-02 syncs), timed_out recorded + metric" eval '[ "$(ro .stage)" = fleet ] && [ "$(lastcall)" = "upgrade wk-02" ] && [ "$(ro .canary_timed_out)" = true ] && [ "$(metric canary_timed_out)" = 1 ]'

# ── the evidence script not there yet: "not yet", logged once, the timeout ends the stage ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1
for i in 1 2 3 4 5; do RECONCILE_EVIDENCE="$T/absent.sh" tick; done   # four canaries, then the first evidence read
check "a missing evidence script → not yet (logged)" eval '[ "$(ro .stage)" = canary ] && [ "$(ro .evidence_missing)" = true ] && grep -q "does not exist" "$T/out"'
RECONCILE_EVIDENCE="$T/absent.sh" tick
check "…logged once per rollout, not every tick" eval '[ "$(ro .stage)" = canary ] && ! grep -q "does not exist" "$T/out"'

# ── a canary override: a node already on the target is its type's canary, not synced again ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1 wk-03=v2; tick
check "wk-03 already on v2 is the vm/L/compute canary; the first sync is nx-01, never wk-02" eval '[ "$(ro ".canaries[\"vm/worker/L/compute\"]")" = wk-03 ] && [ "$(lastcall)" = "upgrade nx-01" ] && [ "$(ro ".nodes[\"wk-03\"].already")" = true ]'

# ── the ranking unreadable → refusal, nothing synced ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1; FAKE_ORDER_FAIL=1 tick
check "ranking unreadable → nothing synced, the nodes pending" eval '[ "$(calls)" = 0 ] && [ "$(st wk-03)" = pending ] && grep -q "ranking is unreadable" "$RECONCILE_DIR/state.json"'

# ── supersede: a newer patch merges mid-rollout ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1; tick; tick   # wk-03 + nx-01 on v2
fleet_targets v3; tick
check "newer target → SUPERSEDED, recorded, back to canary" eval '[ "$(ro .target)" = v3 ] && [ "$(ro .stage)" = canary ] && [ "$(ro ".superseded[0].from")" = v2 ] && [ "$(ro ".superseded[0].to")" = v3 ]'
check "the not-yet nodes skip v2: the new vm/L/compute canary is wk-02 (wk-03 is deferred)" eval '[ "$(lastcall)" = "upgrade wk-02" ] && [ "$(ro ".canaries[\"vm/worker/L/compute\"]")" = wk-02 ] && [ "$(jq -r ".[\"wk-02\"].version" $LIVE)" = v3 ]'
check "nodes already on v2 wait for the NEXT rollout" eval '[ "$(st wk-03)" = pending ] && grep -q "gets v3 in the next one" "$RECONCILE_DIR/state.json" && [ "$(behind wk-03)" = v3 ]'
echo 0 | tee "$EVID/wk-02" "$EVID/wk-01" "$EVID/hp-01" >/dev/null
for i in 1 2 3 4 5 6; do tick; done   # wk-01 hp-01 (canaries) · m70s (evidence → fleet) · cp-01 cp-02 · done
check "the v3 rollout finishes without the deferred nodes" eval '[ "$(ro .stage)" = done ] && [ "$(st wk-03)" = pending ] && [ "$(jq -r ".[\"wk-03\"].version" $LIVE)" = v2 ]'
tick
check "…and the next rollout picks them up (same target: fleet stage, no second canary round)" eval '[ "$(ro .target)" = v3 ] && [ "$(ro .stage)" = fleet ] && [ "$(lastcall)" = "upgrade wk-03" ]'

# ── a human revert commit: an OLDER target → a revert rollout, first the nodes the last one moved ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1; tick; tick   # wk-03, nx-01 on v2
fleet_targets v1; FAKE_DIFFERENTIAL=1 tick
check "older target → a REVERT rollout: no canary, not halted by the differential" eval '[ "$(ro .target)" = v1 ] && [ "$(ro .kind)" = revert ] && [ "$(ro .stage)" = fleet ] && [ "$(lastcall)" = "upgrade wk-03" ]'
FAKE_DIFFERENTIAL=1 tick
check "…the moved nodes first, then done" eval '[ "$(lastcall)" = "upgrade nx-01" ]'

# ── one rollout at a time: a node declared at another version waits ──
rreset; fleet_machines; fleet_targets v2 cp-01=v1 cp-02=v1; fleet_live v1 cp-01=v0; tick
check "cp-01 declared v1 (behind) waits for the v2 rollout" eval '[ "$(ro .target)" = v2 ] && [ "$(st cp-01)" = pending ] && grep -q "waits for the v2 rollout" "$RECONCILE_DIR/state.json" && [ -z "$(behind cp-01)" ]'

# ── the CP verb's contract: exit 4 parks (impossible path), and a parked canary cannot block forever ──
rreset; fleet_machines; fleet_targets v2; fleet_live v2 cp-01=v1; FAKE_CP_RC=4 tick
check "a CP-only rollout skips the canary stage; the CP verb's exit 4 → PARKED" eval '[ "$(lastcall)" = "cp cp-01" ] && [ "$(st cp-01)" = parked ] && [ "$(ro .stage)" = fleet ]'
tick
check "…and the rollout ends (parked is not retried)" eval '[ "$(ro .stage)" = done ] && [ "$(calls)" = 1 ]'

# ── windows still gate a rollout sync ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1; windows '[{"id":"m70s-1","node":"m70s","by":"seat"}]'; tick
check "a declared window refuses the rollout's sync too" eval '[ "$(calls)" = 0 ] && [ "$(st wk-03)" = pending ] && grep -q "another window" "$RECONCILE_DIR/state.json"'

# ── the switch flipped OFF mid-rollout: pressure lifted, the record retired, the pilot scope back ──
rreset; fleet_machines; fleet_targets v2; fleet_live v1; tick
fleet_machines '"reconcile_rollout":{"enabled":false,"pilot":["wk-03"]}'; tick
check "switch off mid-rollout → talos-behind lifted everywhere, rollout.json gone" eval '[ ! -f "$RECONCILE_DIR/rollout.json" ] && [ -z "$(behind nx-01)" ] && other_taints_intact && ! grep -q mgmt_reconcile_rollout "$MGMT_TEXTFILE_DIR/mgmt_reconcile.prom"'

# ═══ FU-278: the workload-health hold ═══════════════════════════════════════════════════════════
PF='forgejo/Deployment/forgejo'; SI='oracle-fleet/Deployment/oracle-fleet-ingester'; SS='circles/Deployment/circles-page'
OLD='monitoring/StatefulSet/broken-before'
healthy_fleet() { whf "$(wl $PF platform 68f79d44d9 true)" "$(wl $SI stack-important aaa true)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)"; }
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1; tick
check "wh: rollout start snapshots every workload (baseline in rollout.json) before the first sync" eval '[ "$(ro ".wh.baseline | length")" = 4 ] && [ "$(ro ".wh.baseline[\"$PF\"].revision")" = 68f79d44d9 ] && [ "$(lastcall)" = "upgrade wk-03" ] && grep -q "1 already unhealthy" "$T/out"'
whf "$(wl $PF platform 68f79d44d9 false)" "$(wl $SI stack-important aaa true)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)"; tick
check "wh: a PLATFORM workload newly unhealthy → HALTED (workload-health), no sync, pressure lifted" eval '[ "$(ro .stage)" = halted ] && [ "$(ro .halt_reason)" = workload-health ] && [ "$(calls)" = 1 ] && [ -z "$(behind nx-01)" ] && other_taints_intact'
check "wh: the hold names workload + revision + since, in the log, the pending reason and the series" eval 'grep -q "HELD on workload health.*$PF@68f79d44d9 (platform, unhealthy since 2026-09-22T12:47:06Z" "$T/out" && grep -q "held on $PF@68f79d44d9" "$RECONCILE_DIR/state.json" && [ "$(metric "workload_held{workload=\"$PF\",class=\"platform\",revision=\"68f79d44d9\"}")" = 1 ] && [ "$(metric "halted{reason=\"workload-health\"}")" = 1 ]'
check "wh: a workload already unhealthy at the snapshot never holds" eval '[ "$(ro "[.wh.held[].key] | join(\",\")")" = "$PF" ]'
tick
check "wh: still unhealthy → still held, nothing synced" eval '[ "$(ro .stage)" = halted ] && [ "$(calls)" = 1 ]'
healthy_fleet; tick
check "wh: healthy again → RESUMED where it was (canary), the next canary syncs, series gone" eval '[ "$(ro .stage)" = canary ] && [ "$(lastcall)" = "upgrade nx-01" ] && [ -z "$(metric workload_held)" ] && [ "$(metric "halted{reason=\"workload-health\"}")" = 0 ]'

# the class × revision split for stack workloads
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1; tick
whf "$(wl $PF platform 68f79d44d9 true)" "$(wl $SI stack-important aaa false)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)"; tick
check "wh: STACK-IMPORTANT unhealthy on the SAME revision as the snapshot → HOLD" eval '[ "$(ro .stage)" = halted ] && [ "$(ro .halt_reason)" = workload-health ] && [ "$(calls)" = 1 ]'
whf "$(wl $PF platform 68f79d44d9 true)" "$(wl $SI stack-important ccc false)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)"; tick
check "wh: …the same workload on a NEW revision → logged, not held (the stack's own change): resumes" eval '[ "$(ro .stage)" = canary ] && [ "$(lastcall)" = "upgrade nx-01" ] && grep -q "$SI (stack-important) unhealthy on revision ccc — logged, not held" "$T/out"'
tick
check "wh: …logged once per revision, not every tick" eval '! grep -q "$SI (stack-important) unhealthy" "$T/out" && [ "$(lastcall)" = "upgrade wk-01" ]'
whf "$(wl $PF platform 68f79d44d9 true)" "$(wl $SI stack-important ccc false)" "$(wl $SS stack-singleton bbb false)" "$(wl $OLD platform s1 false)"; tick
check "wh: a STACK-SINGLETON unhealthy (same revision) → logged only, the rollout goes on" eval '[ "$(lastcall)" = "upgrade hp-01" ] && grep -q "$SS (stack-singleton) unhealthy on revision bbb — logged, not held (a stack singleton)" "$T/out"'
whf "$(wl $PF platform 68f79d44d9 true)" "$(wl $SI stack-important aaa true)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)" "$(wl argocd/Deployment/brand-new platform z false)"; tick
check "wh: a platform workload ABSENT from the snapshot and unhealthy now → HOLD (absent counts as healthy)" eval '[ "$(ro .stage)" = halted ] && [ "$(ro "[.wh.held[].key] | join(\",\")")" = argocd/Deployment/brand-new ]'

# unreadable: at the gate, and at the snapshot
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1; tick
FAKE_WH_UNREADABLE=1 tick
check "wh: the read unreadable → HOLD (workload-health-unreadable), nothing synced" eval '[ "$(ro .stage)" = halted ] && [ "$(ro .halt_reason)" = workload-health-unreadable ] && [ "$(calls)" = 1 ] && [ "$(metric "halted{reason=\"workload-health-unreadable\"}")" = 1 ]'
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1; FAKE_WH_UNREADABLE=1 tick
check "wh: no baseline (unreadable at rollout start) → held before the FIRST window" eval '[ "$(ro .stage)" = halted ] && [ "$(ro .wh.baseline)" = null ] && [ "$(calls)" = 0 ]'
tick
check "wh: …the read back → the baseline is taken then, and the first canary syncs" eval '[ "$(ro ".wh.baseline | length")" = 4 ] && [ "$(ro .stage)" = canary ] && [ "$(lastcall)" = "upgrade wk-03" ]'

# the human ack
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1; tick
whf "$(wl $PF platform 68f79d44d9 false)" "$(wl $SI stack-important aaa true)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)"; tick
touch "$RECONCILE_DIR/workload-health.ack"; tick
check "wh: an ack (touch workload-health.ack) releases the held workloads for this rollout; the file is consumed" eval '[ "$(ro .stage)" = canary ] && [ "$(lastcall)" = "upgrade nx-01" ] && [ ! -e "$RECONCILE_DIR/workload-health.ack" ] && [ "$(ro ".wh.acked | join(\",\")")" = "$PF" ] && grep -q "ACKED by a human" "$T/out"'
whf "$(wl $PF platform 68f79d44d9 false)" "$(wl $SI stack-important aaa true)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)" "$(wl garage/StatefulSet/garage platform g1 false)"; tick
check "wh: …a DIFFERENT workload going bad after the ack still holds" eval '[ "$(ro .stage)" = halted ] && [ "$(ro "[.wh.held[].key] | join(\",\")")" = garage/StatefulSet/garage ]'

# evaluated when the window RETURNS, not only before the next one
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1
whf "$(wl $PF platform 68f79d44d9 false)" "$(wl $SI stack-important aaa true)" "$(wl $SS stack-singleton bbb true)" "$(wl $OLD platform s1 false)" >/dev/null; cp "$WH_FILE" "$T/wh-after"; healthy_fleet
FAKE_WH_AFTER="$T/wh-after" tick
check "wh: a window that leaves a platform workload broken → HALTED in the SAME tick, right after the verb" eval '[ "$(lastcall)" = "upgrade wk-03" ] && [ "$(st wk-03)" = idle ] && [ "$(ro .stage)" = halted ] && [ "$(ro .halt_reason)" = workload-health ] && [ -z "$(behind nx-01)" ]'

# the differential takes precedence; a revert is never held
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1; tick
whf "$(wl $PF platform 68f79d44d9 false)"; FAKE_DIFFERENTIAL=1 tick
check "wh: differential AND a held workload → reason differential" eval '[ "$(ro .halt_reason)" = differential ]'
rreset; healthy_fleet; fleet_machines; fleet_targets v2; fleet_live v1; tick; tick   # wk-03, nx-01 on v2
fleet_targets v1; whf "$(wl $PF platform 68f79d44d9 false)"; tick
check "wh: a REVERT rollout is never held (the revert is the fix)" eval '[ "$(ro .kind)" = revert ] && [ "$(lastcall)" = "upgrade wk-03" ] && [ "$(ro .stage)" = fleet ]'

# ── REPLAY 2026-09-22 (fixtures reconstructed from Prometheus kube-state-metrics, gen.py beside them):
# baseline = the fleet at the rollout's start (09:45Z); after wk-04's window (drain 12:47–12:50Z) the
# read at 12:54:45Z — the moment before the reconciler took cp-01 down (sync 12:55:14Z). ──
FX="$HERE/fixtures/workload-health-2026-09-22"
cat >"$T/wh-replay.sh" <<'EOF'
WH_DIR="$FX/$WH_AT" WH_NOW="$(date -u -d "2026-09-22 ${WH_AT:1:2}:${WH_AT:3:2}:$([ "$WH_AT" = t0945 ] && echo 00 || echo 45)" +%s)" \
  bash "$HERE/node-maintenance.sh" workload-health
EOF
export FX HERE
rreset; fleet_machines; fleet_targets v2; fleet_live v1
WH_AT=t0945 RECONCILE_WORKLOAD_HEALTH_CMD="bash $T/wh-replay.sh" tick
check "replay: the 09:45Z baseline reads every workload healthy (Forgejo on wk-04 included)" eval '[ "$(ro ".wh.baseline[\"forgejo/Deployment/forgejo\"].healthy")" = true ] && [ "$(ro "[.wh.baseline[] | select(.healthy | not)] | length")" = 0 ] && [ "$(lastcall)" = "upgrade wk-03" ]'
WH_AT=t1254 RECONCILE_WORKLOAD_HEALTH_CMD="bash $T/wh-replay.sh" tick
check "replay: 12:54:45Z → HOLD on forgejo/Deployment/forgejo@68f79d44d9 (init configure-gitea CrashLoopBackOff), nothing else" eval '[ "$(ro .stage)" = halted ] && [ "$(ro "[.wh.held[] | \"\(.key)@\(.revision)\"] | join(\",\")")" = "forgejo/Deployment/forgejo@68f79d44d9" ] && grep -q "configure-gitea CrashLoopBackOff" "$T/out" && [ "$(calls)" = 1 ]'
rreset; fleet_machines; fleet_targets v2; fleet_live v1
WH_AT=t0945 RECONCILE_WORKLOAD_HEALTH_CMD="bash $T/wh-replay.sh" tick
WH_AT=t1030 RECONCILE_WORKLOAD_HEALTH_CMD="bash $T/wh-replay.sh" tick
check "replay: 10:30:45Z (before wk-metal-04's window) → HOLD on garage/StatefulSet/garage — garage-2 not Ready 23 min after its zone's window" eval '[ "$(ro "[.wh.held[].key] | join(\",\")")" = garage/StatefulSet/garage ] && grep -q "garage-2: not Ready for 23m" "$T/out"'

# ═══ the READ: node-maintenance.sh workload-health (FU-278) against synthetic dumps ═════════════════
WD="$T/whd"; mkdir -p "$WD"
NOW=1790085000   # 2026-09-22T13:50:00Z
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
pod() {  # <ns> <name> <ownerKind> <ownerName> <ready> <readySince-epoch> [waitingReason] [init] [labels-json] [apiVersion] [phase]
  local l="${9:-}"; [ -n "$l" ] || l='{}'
  jq -nc --arg ns "$1" --arg n "$2" --arg ok "$3" --arg on "$4" --arg r "$5" --arg rs "$(iso "$6")" --arg w "${7:-}" --arg init "${8:-}" \
         --argjson l "$l" --arg av "${10:-apps/v1}" --arg ph "${11:-Running}" '
    {metadata: {namespace: $ns, name: $n, labels: $l, creationTimestamp: $rs,
                ownerReferences: (if $ok == "" then [] else [{kind: $ok, name: $on, controller: true, apiVersion: $av}] end)},
     spec: {containers: [{name: "c", image: "img:1"}]},
     status: {phase: $ph, conditions: [{type: "Ready", status: $r, lastTransitionTime: $rs}],
              containerStatuses: (if $w != "" and $init == "" then [{name: "c", state: {waiting: {reason: $w}}}] else [] end),
              initContainerStatuses: (if $w != "" and $init != "" then [{name: "i", state: {waiting: {reason: $w}}}] else [] end)}}'
}
items() { jq -sc '{items: .}'; }
{ pod forgejo forgejo-abc-1 ReplicaSet forgejo-abc False $((NOW-400)) CrashLoopBackOff init '{"pod-template-hash":"abc"}'
  pod monitoring prom-0 StatefulSet prom True $((NOW-9000))
  pod monitoring slow-1 ReplicaSet slow-r False $((NOW-120))
  pod monitoring stuck-1 ReplicaSet stuck-r False $((NOW-600))
  pod argocd img-1 ReplicaSet img-r False $((NOW-30)) ImagePullBackOff
  pod oracle-fleet ride-1 "" "" False $((NOW-900)) Error
  pod oracle-fleet job-1 Job j False $((NOW-900)) Error
  pod oracle-fleet done-1 ReplicaSet api-r False $((NOW-900)) "" "" '{}' apps/v1 Succeeded
  pod arc-runners runner-1 EphemeralRunner er False $((NOW-900)) Error
  pod oracle-fleet api-1 ReplicaSet api-r True $((NOW-900)) "" "" '{"app":"api"}'
  pod oracle-fleet pg-1 Cluster oracle-pg True $((NOW-900)) "" "" '{}' postgresql.cnpg.io/v1
  pod oracle-fleet solo-1 ReplicaSet solo-r False $((NOW-900)) CreateContainerConfigError
  pod oracle-agents coord-1 ReplicaSet coord-r False $((NOW-900)) CrashLoopBackOff
} | items >"$WD/pods.json"
rs() { jq -nc --arg ns "$1" --arg n "$2" --arg d "$3" --arg h "$4" --arg rev "$5" '{metadata: {namespace: $ns, name: $n, labels: {"pod-template-hash": $h}, annotations: {"deployment.kubernetes.io/revision": $rev}, ownerReferences: [{kind: "Deployment", name: $d}]}}'; }
{ rs forgejo forgejo-abc forgejo abc 7; rs forgejo forgejo-old forgejo old 6; rs monitoring slow-r slow s 1; rs monitoring stuck-r stuck t 1
  rs argocd img-r img i 1; rs oracle-fleet api-r api a 1; rs oracle-fleet solo-r solo so 1; rs oracle-agents coord-r coord c 1; } | items >"$WD/replicasets.json"
dep() { jq -nc --arg ns "$1" --arg n "$2" --argjson r "$3" '{metadata: {namespace: $ns, name: $n}, spec: {replicas: $r}}'; }
{ dep forgejo forgejo 1; dep oracle-fleet api 1; dep oracle-fleet solo 1; dep oracle-agents coord 1; } | items >"$WD/deployments.json"
echo '{"items":[{"metadata":{"namespace":"monitoring","name":"prom"},"spec":{"replicas":1},"status":{"updateRevision":"prom-77"}}]}' >"$WD/statefulsets.json"
echo '{"items":[]}' >"$WD/daemonsets.json"
echo '{"items":[{"metadata":{"namespace":"oracle-fleet","name":"api-pdb"},"spec":{"selector":{"matchLabels":{"app":"api"}}}}]}' >"$WD/pdb.json"
echo '{"items":[{"metadata":{"namespace":"oracle-fleet","name":"oracle-pg"},"spec":{"instances":2}}]}' >"$WD/clusters.json"
echo '{"items":[{"metadata":{"name":"oracle"},"spec":{"repos":[{"name":"oracle-fleet"},{"name":"oracle-iac"}]}},{"metadata":{"name":"platform"},"spec":{"repos":[{"name":"homelab"},{"name":"agent-coordinator"}]}}]}' >"$WD/agentstacks.json"
whrun() { WH_DIR="$WD" WH_NOW=$NOW bash "$HERE/node-maintenance.sh" workload-health >"$T/whout" 2>"$T/out"; echo $? >"$T/rc"; }
wget_() { jq -r --arg k "$1" --arg f "$2" 'select(.key == $k) | .[$f] | tostring' "$T/whout"; }
whrun
check "read: exit 0, one line per TOP OWNER (ReplicaSet → Deployment, CNPG → Cluster.postgresql.cnpg.io)" eval '[ "$(cat $T/rc)" = 0 ] && [ "$(wget_ forgejo/Deployment/forgejo healthy)" = false ] && [ "$(wget_ oracle-fleet/Cluster.postgresql.cnpg.io/oracle-pg healthy)" = true ]'
check "read: init container CrashLoopBackOff → unhealthy, named; revision = the CURRENT ReplicaSet hash" eval '[ "$(wget_ forgejo/Deployment/forgejo revision)" = abc ] && grep -q "forgejo-abc-1: init i CrashLoopBackOff" "$T/whout"'
check "read: not Ready 2 min → healthy (grace), 10 min → unhealthy; ImagePullBackOff at once" eval '[ "$(wget_ monitoring/Deployment/slow healthy)" = true ] && [ "$(wget_ monitoring/Deployment/stuck healthy)" = false ] && [ "$(wget_ argocd/Deployment/img healthy)" = false ]'
check "read: bare (ride), Job, EphemeralRunner and finished pods are not workloads" eval '! grep -qE "ride-1|job-1|runner-1|done-1|/Job/|EphemeralRunner" "$T/whout"'
check "read: StatefulSet revision = updateRevision" eval '[ "$(wget_ monitoring/StatefulSet/prom revision)" = prom-77 ]'
check "read: classes — stack ns from the claims (platform claim excluded); PDB or ≥2 instances = important" eval '[ "$(wget_ oracle-fleet/Deployment/api class)" = stack-important ] && [ "$(wget_ oracle-fleet/Cluster.postgresql.cnpg.io/oracle-pg class)" = stack-important ] && [ "$(wget_ oracle-fleet/Deployment/solo class)" = stack-singleton ] && [ "$(wget_ oracle-agents/Deployment/coord class)" = platform ] && [ "$(wget_ forgejo/Deployment/forgejo class)" = platform ]'
check "read: since = the pod going not-Ready" eval '[ "$(wget_ forgejo/Deployment/forgejo since)" = "$(iso $((NOW-400)))" ]'
mv "$WD/agentstacks.json" "$WD/agentstacks.json.x"; whrun
check "read: the claims unreadable → exit 1, NOTHING printed (never a guessed class)" eval '[ "$(cat $T/rc)" = 1 ] && [ ! -s "$T/whout" ]'
mv "$WD/agentstacks.json.x" "$WD/agentstacks.json"; echo '{"items":[]}' >"$WD/pods.json"; whrun
check "read: an empty pod list is a failed read, not a healthy fleet" eval '[ "$(cat $T/rc)" = 1 ] && [ ! -s "$T/whout" ]'

# ═══ the health check itself: node-maintenance.sh verify (FU-276) — read-only, fail-closed ═══════
# A fake kubectl/talosctl on PATH (no cluster). $VF holds the case's switches; every kubectl call is
# recorded, so the suite can assert verify never mutates anything.
VB="$T/vbin"; export VF="$T/vf"; mkdir -p "$VB" "$VF"
cat >"$VB/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$VF/kcalls"
has() { [ -f "$VF/$1" ]; }
has all-fail && exit 1
case "$*" in
  *"get node wk-03 -o jsonpath={.status.conditions"*) echo True ;;
  *"get node wk-03 -o jsonpath={.spec.unschedulable}"*) : ;;
  *"get node wk-03 -o jsonpath={.status.nodeInfo.osImage}"*) echo "Talos (v2)" ;;
  *"get node wk-03 -o jsonpath={.status.addresses"*) echo 10.0.0.3 ;;
  *"get nodes.longhorn.io wk-03 -o name"*) echo 'Error from server (NotFound): nodes.longhorn.io "wk-03" not found' >&2; exit 1 ;;
  *"get pdb -A -o json"*) echo '{"items":[]}' ;;
  *"get pods -A"*) echo '{"items":[]}' ;;
  *"get clusters.postgresql.cnpg.io"*) has cnpg-fail && exit 1; echo '{"items":[]}' ;;
  *"get nodes -l node-role.kubernetes.io/control-plane -o json"*)
    echo '{"items":[{"metadata":{"name":"cp-01"},"spec":{},"status":{"conditions":[{"type":"Ready","status":"True"}],"addresses":[{"type":"InternalIP","address":"10.0.0.1"}]}}]}' ;;
  *"get pod -l k8s-app=cilium --field-selector spec.nodeName=wk-03 -o json"*)
    r=True; has cilium-unready && r=False
    echo '{"items":[{"metadata":{"name":"cilium-x"},"status":{"phase":"Running","conditions":[{"type":"Ready","status":"'$r'"}]}}]}' ;;
  *"exec"*cilium-dbg*) has cilium-hung && exit 1
    printf 'ID Frontend Service Backend\n10 10.96.0.1:443/TCP ClusterIP 1 => 10.0.0.1:6443/TCP (active)\n' ;;
  *) exit 1 ;;
esac
EOF
cat >"$VB/talosctl" <<'EOF'
#!/usr/bin/env bash
echo "NODE NAMESPACE TYPE ID VERSION NAME VERSION"
echo "10.0.0.3 runtime ExtensionStatus 0 1 schematic s"
EOF
chmod +x "$VB/kubectl" "$VB/talosctl"
echo '{"wk-03":{"version":"v2","schematic":"s","role":"worker"}}' >"$T/vtargets.json"
vrun() { rm -f "$VF/kcalls"; PATH="$VB:$PATH" KUBECONFIG=/dev/null TALOSCONFIG=/dev/null INSTALL_TARGETS="$T/vtargets.json" NM_AM=http://127.0.0.1:9 \
           bash "$HERE/node-maintenance.sh" verify wk-03 >"$T/out" 2>&1; echo $? >"$T/rc"; }
no_writes() { ! grep -qE '(^| )(cordon|uncordon|drain|taint|label|annotate|apply|delete|patch|create|scale|rollout) ' "$VF/kcalls"; }
rm -f "$VF"/*; vrun
check "verify: healthy node → exit 0, and not one mutating kubectl call" eval '[ "$(cat $T/rc)" = 0 ] && no_writes && grep -q "verify: wk-03 healthy" "$T/out"'
rm -f "$VF"/*; touch "$VF/cilium-hung"; vrun
check "verify: cilium-agent on the node does not answer (nx-01) → exit 1, named" eval '[ "$(cat $T/rc)" = 1 ] && grep -q "does not answer" "$T/out" && no_writes'
rm -f "$VF"/*; touch "$VF/cilium-unready"; vrun
check "verify: cilium-agent not Ready → exit 1" eval '[ "$(cat $T/rc)" = 1 ] && grep -q "not Ready" "$T/out"'
rm -f "$VF"/*; touch "$VF/cnpg-fail"; vrun
check "verify: CNPG unreadable → exit 1 (an unreadable floor is a fail)" eval '[ "$(cat $T/rc)" = 1 ] && grep -q "cannot read CNPG" "$T/out"'
rm -f "$VF"/*; touch "$VF/all-fail"; vrun
check "verify: the API unreachable → exit 1, never 0" eval '[ "$(cat $T/rc)" = 1 ]'
echo '{"wk-03":{"version":"v3","schematic":"s","role":"worker"}}' >"$T/vtargets.json"; rm -f "$VF"/*; vrun
check "verify: live version is not the declared one → exit 1" eval '[ "$(cat $T/rc)" = 1 ] && grep -q "declared v3" "$T/out"'

echo "mgmt-reconcile-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
