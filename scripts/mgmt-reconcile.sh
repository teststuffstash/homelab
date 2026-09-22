#!/usr/bin/env bash
# mgmt-reconcile — the management box's NODE reconciler (ADR-132 §MB4 layers 3–5,
# docs/management-box.md §MB4). For every node `machines/machines.yaml` declares `reconcile: auto`,
# it compares the DECLARED install (node_install_targets from main's applied state — the same
# expression the upgrade verb passes as --image) with LIVE (mgmt-probe.sh's own node diff, run for
# those nodes only), and when the version or schematic axis differs it runs the existing verb:
# `node-maintenance.sh upgrade <node>` (a control plane: `controlplane-upgrade.sh <node>`). It adds
# only what the verb does not know:
#
#   WIP 1        one sync per tick and the unit is a oneshot, so one window at a time by
#                construction; ANY live declared window (agents/seat-window.sh's record) refuses
#                the tick — on another node, seat-wide, or on the target itself — unless it is on
#                the target AND was opened with --admit-reconciler (the attended canary). The
#                check runs BEFORE the verb opens its own window, so a window on the target at
#                that moment is always someone else's. The verb's own WIP 1 (no other node cordoned or
#                NotReady) and its fleet floors (Longhorn degraded, a multi-node PDB at 0 — Garage's, CNPG
#                instances) stay the verb's — they are not re-implemented here.
#   one attempt  keyed on the DECLARED target (version/schematic). A verb exit 2 is a REFUSAL
#                (a gate said no, nothing was touched) and is retried on the next tick; exit 4 is an
#                impossible declared path; any other non-zero exit — or a zero exit that leaves the
#                diff non-zero, or a sync the loop died in the middle of — PARKS the node on that key.
#                A parked node is never retried for the same key: a bad disk must not become a
#                reinstall loop. A NEW declared key (the next commit) un-parks it. The park records
#                its CAUSE, and the cause decides what the diff reaching zero means (FU-276, #1884):
#                a `diff-disagrees` / `impossible` park clears on diff zero (the diff is what
#                failed); a `verb-failed` / `interrupted` park does NOT — there the version is
#                usually already right (nx-01, 2026-09-22: rebooted onto the target, exit 1 on a
#                hung cilium-agent, "cleared" two minutes later), so it clears only when the
#                READ-ONLY `node-maintenance.sh verify <node>` passes (Ready + uncordoned, the
#                Longhorn/budget/CNPG floors, the declared version+schematic, cilium on that node);
#                until then it stays parked and out of INSYNC. An unreadable verify is a fail.
#                By hand: `rm /var/lib/mgmt/reconcile/state.json` (or edit the node's entry).
#   its window   a verb that exits non-0/2/4 leaves its window OPEN by design (Ready timeout, a
#                failed floor or verify). At park time the reconciler closes THAT window —
#                `node-maintenance.sh silence-close <node>`, which touches only the records the
#                verb made (`--by node-maintenance.sh`, its own silences), never a seat's — so the
#                broken node's alerts reach a person and the park is the one record. Without it the
#                leftover window refused every next tick (WIP 1) until SILENCE_HOURS ran out. The
#                same on an `interrupted` park. A node the verb left cordoned still stops the next
#                sync — through the verb's own live WIP 1, which is the right stop.
#   rollback     after a GOOD boot Talos removes the upgrade fallback (`removing fallback entry` in
#                machined's log, nx-01 2026-09-22), so `talosctl rollback` works only in the short
#                window after the upgrade reboot; after that, backing out across a minor is a
#                reinstall. Within a minor, reverting the declaration is the rollback (below).
#   state        /var/lib/mgmt/reconcile/state.json on the box (per node) + rollout.json beside it
#                (the fleet rollout, below), surfaced as mgmt_reconcile_* through the node_exporter
#                textfile — never a commit (§MB4 layer 5).
#
# THE FLEET ROLLOUT (FU-273, §MB4 "The rollout as built") — gated by ONE switch in machines.yaml,
# `reconcile_rollout.enabled`. Switch OFF: the reconciler owns only `reconcile_rollout.pilot` (absent
# = every auto node), picks the first candidate in inventory order, refuses a control plane — the
# pre-rollout behaviour, byte-for-byte (the tests pin it). Switch ON, over every auto node:
#
#   target       a rollout moves ONE declared version across the fleet: the newest declared version
#                among the nodes with a diff. Its members are the auto nodes declared at it (a canary
#                override that already runs it is a member, already done). One rollout at a time: a
#                node declared at another version waits for this one to finish.
#   canary       stage 1: one canary per node TYPE (class × role × schematic from node_install_targets,
#                × storage — `order`'s GARAGE/LH columns), the least risky of each, synced one per
#                tick; then the stage waits until mgmt-rollout-evidence.sh says EXERCISED for every
#                canary, bounded by RECONCILE_CANARY_TIMEOUT (4h) — on timeout it advances ANYWAY and
#                says so (mgmt_reconcile_rollout_canary_timed_out, MgmtRolloutCanaryTimedOut): default
#                forward, never a wall-clock soak that blocks. Control planes are never canaries.
#   fleet        stage 2: the rest in `node-maintenance.sh order`'s ranking (least dangerous first),
#                workers before control planes; a CP only when no worker of the rollout is left to
#                sync, through controlplane-upgrade.sh (etcd quorum, snapshot, cilium gate).
#   halt         MgmtRolloutDifferential firing (or unreadable — an unreadable gate is a no) → stage
#                `halted`: no new sync, the pressure taints lifted; it resumes when the alert clears.
#   hold         (FU-278, operator ruling 2026-09-22) the WORKLOAD read. At rollout start the loop
#                snapshots every workload's health (`node-maintenance.sh workload-health`: top owner,
#                class, revision, healthy) into rollout.json; after each window returns and again
#                before each next one it re-reads and compares. A workload unhealthy NOW that was
#                healthy (or absent) in the snapshot: PLATFORM (any non-stack namespace) → HOLD,
#                whatever its revision; STACK-IMPORTANT (≥2 replicas/instances or a PDB) on the SAME
#                revision as the snapshot → HOLD (likely the rollout); a stack workload on a NEW
#                revision, or a STACK-SINGLETON → logged once, never a hold. Already unhealthy at the
#                snapshot → never holds. An unreadable read (or no baseline yet) → hold. The hold is
#                stage `halted` with reason `workload-health` (`-unreadable`): no new sync, pressure
#                lifted, nothing reverted; it names each workload, revision and since-when, and
#                releases when the held workloads are healthy again OR a human acks:
#                `touch /var/lib/mgmt/reconcile/workload-health.ack` on the box acknowledges every
#                workload held at that moment for the rest of this rollout (the file is consumed; a
#                workload that goes bad later still holds). Never on a revert rollout — the
#                differential's carve-out, for the same reason: the revert is the fix.
#                Nothing is ever reverted here — a revert is a human commit; a declared target OLDER
#                than the last rollout's starts a `revert` rollout (no canary, not halted by the
#                differential, the nodes the last rollout moved go first).
#   pressure     every member not yet on the target carries homelab.io/talos-behind=<target>:
#                PreferNoSchedule, removed as each one syncs and from all when the rollout ends,
#                halts, or the declaration moves on. Only that key is ever touched.
#   supersede    a NEWER target mid-rollout: the not-yet nodes switch to it (skipping the
#                intermediate version — fine within a minor; a skipped minor is the verb's exit 4),
#                the ones already synced to the old target get the new one in the NEXT rollout,
#                and the stage restarts at canary (the new version has proved nothing yet).
#
# What it deliberately does NOT do: labels/taints drift is reported by the belt and left alone
# (tofu's apply path owns them — `mgmt_node_drift`, MgmtNodeLiveStateDrift; the talos-behind key is
# not one tofu declares, so the belt never reads it); ephemeral_disk drift is reinstall-class (Talos
# never re-partitions) and stays a human window; a `manual` node's diff is drift on the belt and
# nothing else; it never runs tofu.
#
# Exit 0 = the tick evaluated (any verdict). Exit 1 = it could not read an input; nothing was run
# and last-run is not stamped, so MgmtReconcileLoopStale sees a loop that cannot look.
#
# Test seams (scripts/mgmt-reconcile-test.sh — the state machine against a fake verb):
#   RECONCILE_DIR  RECONCILE_MACHINES_JSON  RECONCILE_TARGETS_JSON  RECONCILE_WINDOWS_JSON
#   RECONCILE_DIFF_CMD "<cmd> <targets-file> <drift-out>"   RECONCILE_VERB "<cmd> upgrade <node>"
#   RECONCILE_VERIFY "<cmd> <node>" (the health check; 0 = pass)
#   RECONCILE_WINDOW_CLOSE "<cmd> <node>" (closes the verb's own window records)   MGMT_TEXTFILE_DIR
#   rollout: RECONCILE_CP_VERB "<cmd> <node>"   RECONCILE_ORDER_CMD "<cmd>" (order's TSV rows)
#            RECONCILE_EVIDENCE <path> (run as `bash <path> <node> <since>`)
#            RECONCILE_DIFFERENTIAL_CMD "<cmd>" (prints the firing count; non-zero exit = unreadable)
#            RECONCILE_KUBECTL "<cmd>" (kubectl for the taints)   RECONCILE_CANARY_TIMEOUT (s)
#            RECONCILE_WORKLOAD_HEALTH_CMD "<cmd>" (workload-health's JSON lines; non-zero = unreadable)
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
export HOME="${HOME:-/root}"
DIR="${RECONCILE_DIR:-/var/lib/mgmt/reconcile}"
STATE="$DIR/state.json"
RO_FILE="$DIR/rollout.json"   # its own file: `rm state.json` (clearing a park) must not restart a rollout
TEXTDIR="${MGMT_TEXTFILE_DIR:-/var/lib/node-exporter-textfile}"
MAIN_STATE="${MAIN_STATE:-/var/lib/mgmt/state/main/terraform.tfstate}"
CANARY_TIMEOUT="${RECONCILE_CANARY_TIMEOUT:-14400}"
EVIDENCE="${RECONCILE_EVIDENCE:-$REPO/scripts/mgmt-rollout-evidence.sh}"
PROM="${NM_PROM:-http://192.168.40.13:9090}"
TAINT_KEY=homelab.io/talos-behind
WH_ACK="$DIR/workload-health.ack"   # FU-278: a human's ack of the workloads held right now
mkdir -p "$DIR" || exit 1
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
now() { date -u +%s; }

exec 9>"$DIR/.lock"; flock -n 9 || { log "another tick holds the lock — a sync is running"; exit 0; }

ST='{}'; [ -s "$STATE" ] && ST="$(jq -c . "$STATE" 2>/dev/null)" || true
[ -n "$ST" ] || { log "FATAL state file $STATE does not parse — refusing to guess (fix or remove it)"; exit 1; }
RO=''; if [ -s "$RO_FILE" ]; then RO="$(jq -c . "$RO_FILE" 2>/dev/null)" || RO=''
  [ -n "$RO" ] || { log "FATAL rollout file $RO_FILE does not parse — refusing to guess (fix or remove it)"; exit 1; }; fi
rollout_on=false
save() {
  local t; t="$(mktemp "$DIR/.state.XXXXXX")" && printf '%s\n' "$ST" >"$t" && mv -f "$t" "$STATE"
  if [ -n "$RO" ]; then t="$(mktemp "$DIR/.state.XXXXXX")" && printf '%s\n' "$RO" >"$t" && mv -f "$t" "$RO_FILE"; fi
}
set_node() {  # <node> <state> <key> <reason> [cause — parks only: verb-failed|interrupted|diff-disagrees|impossible|guard]
  ST="$(jq -c --arg n "$1" --arg s "$2" --arg k "$3" --arg r "$4" --arg c "${5:-}" --argjson t "$(now)" \
    '.[$n] = ((.[$n] // {}) + {state:$s, key:$k, reason:$r, cause:$c}
              + (if (.[$n].state // "") != $s then {since:$t} else {} end))' <<<"$ST")"
}
field() { jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // ""' <<<"$ST"; }
# A park's cause. A park written before causes existed (no field) is read from its reason, so a
# box upgraded mid-park does not clear a failed-verb park on the diff alone.
park_cause() {
  local c; c="$(field "$1" cause)"
  if [ -z "$c" ]; then case "$(field "$1" reason)" in
    "verb exited 0 but"*) c=diff-disagrees ;;   # the old exit-0 park shares the prefix below (review, #1887)
    "verb exited "*) c=verb-failed ;; interrupted*) c=interrupted ;; esac; fi
  printf '%s' "$c"
}
# The read-only health check a verb-failed/interrupted park must pass before diff zero clears it
# (node-maintenance.sh verify: never cordons, drains or opens a window). Non-zero = not healthy OR
# could not tell — the same answer (rule #6: never fail into a write).
node_verify() {  # <node>
  if [ -n "${RECONCILE_VERIFY:-}" ]; then $RECONCILE_VERIFY "$1"; return; fi
  ( cd "$REPO" && INSTALL_TARGETS="$tf" devbox run --quiet -- bash scripts/node-maintenance.sh verify "$1" )
}
# Close the window the verb left open (its own silences + its `--by node-maintenance.sh` declared
# record — silence-close touches nothing else, a seat's window least of all). Best effort: a
# failure is logged, and the leftover window then refuses ticks until it expires, as before.
close_verb_window() {  # <node>
  local rc=0
  if [ -n "${RECONCILE_WINDOW_CLOSE:-}" ]; then $RECONCILE_WINDOW_CLOSE "$1" || rc=$?
  else ( cd "$REPO" && devbox run --quiet -- bash scripts/node-maintenance.sh silence-close "$1" ) || rc=$?; fi
  if [ "$rc" = 0 ]; then log "$1: closed the verb's own window (silences + its declared record) — the park is the record now"
  else log "$1: closing the verb's own window FAILED (exit $rc) — it blocks new syncs until it expires"; fi
}

emit() {  # [stamp]
  [ -d "$TEXTDIR" ] || return 0
  [ "${1:-}" = stamp ] && now >"$DIR/last-run"
  local lr body tmp; lr="$(cat "$DIR/last-run" 2>/dev/null)"
  body="$(jq -r --argjson lr "${lr:-0}" '
    "# HELP mgmt_reconcile_last_run_timestamp_seconds Last tick of the node reconciler that evaluated (any verdict).",
    "# TYPE mgmt_reconcile_last_run_timestamp_seconds gauge",
    "mgmt_reconcile_last_run_timestamp_seconds \($lr)",
    "# HELP mgmt_reconcile_node_state 1 for the state a reconcile:auto node is in (idle|pending|syncing|parked).",
    "# TYPE mgmt_reconcile_node_state gauge",
    (to_entries[] | .key as $n | .value.state as $s
      | ("idle","pending","syncing","parked") as $x
      | "mgmt_reconcile_node_state{node=\"\($n)\",state=\"\($x)\"} \(if $s == $x then 1 else 0 end)"),
    "# HELP mgmt_reconcile_sync_started_timestamp_seconds When the running sync of this node began (0 = none running).",
    "# TYPE mgmt_reconcile_sync_started_timestamp_seconds gauge",
    (to_entries[] | "mgmt_reconcile_sync_started_timestamp_seconds{node=\"\(.key)\"} \(if .value.state == "syncing" then .value.since else 0 end)")
  ' <<<"$ST")" || return 0
  # The rollout's series exist only while the switch is on — switch off, the file is what it was.
  if [ "$rollout_on" = true ] && [ -n "$RO" ]; then
    body+=$'\n'"$(jq -r '
      "# HELP mgmt_reconcile_rollout_stage 1 for the stage the fleet rollout of target is in (canary|fleet|done|halted).",
      "# TYPE mgmt_reconcile_rollout_stage gauge",
      (.target as $t | .kind as $k | .stage as $s | ("canary","fleet","done","halted") as $x
        | "mgmt_reconcile_rollout_stage{target=\"\($t)\",kind=\"\($k)\",stage=\"\($x)\"} \(if $s == $x then 1 else 0 end)"),
      "# HELP mgmt_reconcile_rollout_started_timestamp_seconds When the current (or last) fleet rollout began.",
      "# TYPE mgmt_reconcile_rollout_started_timestamp_seconds gauge",
      "mgmt_reconcile_rollout_started_timestamp_seconds{target=\"\(.target)\"} \(.started_at)",
      "# HELP mgmt_reconcile_rollout_halted 1 while the rollout is halted, by reason (differential = MgmtRolloutDifferential firing, unreadable = the box could not read it, workload-health = a workload went unhealthy since the rollout started (FU-278), workload-health-unreadable = the workload read failed).",
      "# TYPE mgmt_reconcile_rollout_halted gauge",
      (. as $r | ("differential","unreadable","workload-health","workload-health-unreadable") as $x
        | "mgmt_reconcile_rollout_halted{reason=\"\($x)\"} \(if $r.stage == "halted" and $r.halt_reason == $x then 1 else 0 end)"),
      "# HELP mgmt_reconcile_rollout_workload_held 1 per workload the rollout is held on (FU-278): unhealthy now, healthy at the rollout-start snapshot.",
      "# TYPE mgmt_reconcile_rollout_workload_held gauge",
      (if .stage == "halted" and .halt_reason == "workload-health" then (.wh.held // [])[] else empty end
        | "mgmt_reconcile_rollout_workload_held{workload=\"\(.key)\",class=\"\(.class)\",revision=\"\(.revision | gsub("[\"\\\\]"; ""))\"} 1"),
      "# HELP mgmt_reconcile_rollout_canary_wait_started_timestamp_seconds When the canary stage began waiting for evidence (0 = not waiting).",
      "# TYPE mgmt_reconcile_rollout_canary_wait_started_timestamp_seconds gauge",
      "mgmt_reconcile_rollout_canary_wait_started_timestamp_seconds \(if .stage == "canary" then .canary_wait_started else 0 end)",
      "# HELP mgmt_reconcile_rollout_canary_timed_out 1 when this rollout left its canary stage on the timeout, without evidence for every canary.",
      "# TYPE mgmt_reconcile_rollout_canary_timed_out gauge",
      "mgmt_reconcile_rollout_canary_timed_out \(if .canary_timed_out and .stage != "done" then 1 else 0 end)",
      "# HELP mgmt_reconcile_rollout_canary_exercised 1 once mgmt-rollout-evidence.sh said the canary of this type was exercised on the target.",
      "# TYPE mgmt_reconcile_rollout_canary_exercised gauge",
      (.evidence as $e | .canaries | to_entries[]
        | "mgmt_reconcile_rollout_canary_exercised{node=\"\(.value)\",type=\"\(.key)\"} \(if $e[.value] then 1 else 0 end)"),
      "# HELP mgmt_reconcile_rollout_node_synced_timestamp_seconds When this rollout synced the node (to the target label).",
      "# TYPE mgmt_reconcile_rollout_node_synced_timestamp_seconds gauge",
      (.nodes | to_entries[]
        | "mgmt_reconcile_rollout_node_synced_timestamp_seconds{node=\"\(.key)\",target=\"\(.value.target)\"} \(.value.synced_at)")
    ' <<<"$RO")" || return 0
  fi
  tmp="$(mktemp "$TEXTDIR/.mgmt_reconcile.XXXXXX")" || return 0
  printf '%s\n' "$body" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTDIR/mgmt_reconcile.prom"
}

# ── 1. a sync this loop was in the middle of when it died (box reboot, unit timeout) ─────────────
# The lock is ours, so nothing is running it any more. The attempt is spent: park, never resume —
# the node may be anywhere between cordoned and half-installed, and that is a human read.
for n in $(jq -r 'to_entries[] | select(.value.state == "syncing") | .key' <<<"$ST"); do
  log "$n: found mid-sync with no running tick — PARKED (interrupted; the attempt is spent)"
  set_node "$n" parked "$(field "$n" key)" "interrupted: the loop died mid-sync (reboot/timeout) — read the node; clears once diff zero AND node-maintenance.sh verify passes" interrupted
  close_verb_window "$n"
done
save

# ── 2. the policy: reconcile:auto nodes (default manual) + the rollout switch ────────────────────
if [ -n "${RECONCILE_MACHINES_JSON:-}" ]; then mj="$(cat "$RECONCILE_MACHINES_JSON")"
else mj="$(cd "$REPO" && devbox run --quiet -- yq -o=json machines/machines.yaml 2>/dev/null)"; fi
auto="$(jq -r '.machines[] | select(.reconcile == "auto") | .name' <<<"$mj" 2>/dev/null)" \
  || { log "FATAL machines/machines.yaml unreadable — no tick"; emit; exit 1; }
[ "$(jq -r '.reconcile_rollout.enabled // false' <<<"$mj" 2>/dev/null)" = true ] && rollout_on=true
if [ "$rollout_on" != true ]; then
  # Switch off: the pilot scope (absent = every auto node — the reconciler's original semantics).
  auto="$(jq -r --arg a "$auto" '.reconcile_rollout.pilot as $p | $a | split("\n")[] | select(length > 0)
                                 | . as $n | select($p == null or ($p | index($n)) != null)' <<<"$mj")"
fi
# A node that left `auto` (or the inventory) leaves the state and the metrics with it.
ST="$(jq -c --argjson keep "$(printf '%s\n' "$auto" | jq -R . | jq -sc 'map(select(length > 0))')" \
      'with_entries(select(.key as $k | $keep | index($k)))' <<<"$ST")"

# kubectl from the box, for the pressure taints (the windows read below keeps its own call).
kube() {
  if [ -n "${RECONCILE_KUBECTL:-}" ]; then $RECONCILE_KUBECTL "$@"; return; fi
  local kc="${KUBECONFIG:-}"; [ -f "$kc" ] || kc=/var/lib/mgmt/kubeconfig
  ( cd "$REPO" && devbox run --quiet -- kubectl --kubeconfig "$kc" "$@" )
}
# The pressure (FU-273): the listed nodes carry TAINT_KEY=<target>:PreferNoSchedule, every other node
# loses the key. Idempotent, and only this key is ever read or written. A failure is logged and
# never gates anything — the taint is a preference, the verb's gates are the gates.
reconcile_taints() {  # <target> [node...]
  local t="$1"; shift
  local want nodes n eff
  want="$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))')"
  if ! nodes="$(kube get nodes -o json 2>/dev/null)" || ! jq -e '.items' >/dev/null 2>&1 <<<"$nodes"; then
    log "pressure: cannot read the nodes — $TAINT_KEY not reconciled this tick (a preference, never a gate)"; return 0
  fi
  while IFS=$'\t' read -r n eff; do
    [ -n "$n" ] || continue
    if kube taint node "$n" "$TAINT_KEY:$eff-" >/dev/null 2>&1; then log "pressure: $n — $TAINT_KEY:$eff removed"
    else log "pressure: $n — removing $TAINT_KEY:$eff FAILED"; fi
  done < <(jq -r --arg k "$TAINT_KEY" --argjson w "$want" '.items[] | .metadata.name as $n
             | (.spec.taints // [])[] | select(.key == $k)
             | select(($w | index($n)) == null or .effect != "PreferNoSchedule") | "\($n)\t\(.effect)"' <<<"$nodes")
  for n in $(jq -r --arg k "$TAINT_KEY" --arg t "$t" --argjson w "$want" '.items[]
               | select(.metadata.name as $n | $w | index($n) != null)
               | select(any((.spec.taints // [])[]; .key == $k and .value == $t and .effect == "PreferNoSchedule") | not)
               | .metadata.name' <<<"$nodes"); do
    if kube taint node "$n" "$TAINT_KEY=$t:PreferNoSchedule" --overwrite >/dev/null 2>&1; then
      log "pressure: $n — tainted $TAINT_KEY=$t:PreferNoSchedule"
    else log "pressure: $n — tainting FAILED"; fi
  done
}

# Switch turned off with a rollout on record: lift its pressure and forget it (the pilot scope has
# no rollout). Only reachable when rollout.json exists, so the switch-off path is otherwise unchanged.
if [ "$rollout_on" != true ] && [ -n "$RO" ]; then
  log "rollout switch is OFF — lifting $TAINT_KEY and retiring the rollout record ($(jq -r '"\(.target) \(.stage)"' <<<"$RO"))"
  reconcile_taints "$(jq -r .target <<<"$RO")"
  RO=''; rm -f "$RO_FILE"
fi
if [ -z "$auto" ]; then log "no node declares reconcile: auto — nothing to reconcile"; save; emit stamp; exit 0; fi
log "reconcile:auto$([ "$rollout_on" = true ] && echo " (fleet rollout ON)") — $(tr '\n' ' ' <<<"$auto")"

# ── 3. the declaration: node_install_targets from main's APPLIED state ───────────────────────────
tf="$(mktemp)"; df="$(mktemp)"; trap 'rm -f "$tf" "$df" "$tf.auto"' EXIT
if [ -n "${RECONCILE_TARGETS_JSON:-}" ]; then cp "$RECONCILE_TARGETS_JSON" "$tf"
else
  [ -f "$MAIN_STATE" ] || { log "FATAL no main state at $MAIN_STATE — the reconciler runs on the box"; emit; exit 1; }
  if [ ! -d "$REPO/tofu/.terraform" ]; then
    ( cd "$REPO" && devbox run --quiet -- tofu -chdir=tofu init -input=false -lockfile=readonly >/dev/null 2>&1 ) \
      || { log "FATAL cannot initialise the main root — declaration unreadable"; emit; exit 1; }
  fi
  ( cd "$REPO" && devbox run --quiet -- tofu -chdir=tofu output -state="$MAIN_STATE" -json node_install_targets ) >"$tf" 2>/dev/null \
    || { log "FATAL tofu output node_install_targets failed"; emit; exit 1; }
fi
jq -e 'type == "object"' "$tf" >/dev/null 2>&1 || { log "FATAL node_install_targets is not a map"; emit; exit 1; }
jq -c --argjson a "$(printf '%s\n' "$auto" | jq -R . | jq -sc .)" 'with_entries(select(.key as $k | $a | index($k)))' "$tf" >"$tf.auto"
keyof()  { jq -r --arg n "$1" '.[$n] | "\(.version)/\(.schematic)"' "$tf"; }
decl()   { jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // ""' "$tf"; }   # <node> <field>

# ── 4. the diff: mgmt-probe.sh's check_nodes, for the auto nodes only ────────────────────────────
# ONE diff (§MB4 layer 1: the detector first, the sync's completion condition second). DRY_RUN=1:
# this call must never overwrite the belt's own textfile.
diff_nodes() {  # <targets-file> <out>
  if [ -n "${RECONCILE_DIFF_CMD:-}" ]; then $RECONCILE_DIFF_CMD "$1" "$2"; return; fi
  MODE=belt DRY_RUN=1 SKIP="tofu talos ansible creds" NODE_TARGETS_JSON="$1" NODE_DRIFT_OUT="$2" \
    bash "$REPO/scripts/mgmt-probe.sh" >/dev/null 2>&1
  [ -s "$2" ]
}
diff_nodes "$tf.auto" "$df" || { log "FATAL the node diff produced nothing — no tick"; emit; exit 1; }
axis() { awk -F'\t' -v k="$1 $2" '$1 == k {print $2; exit}' "$df"; }   # <node> <axis> → drift|ok|""

# ── 5. per node: idle / parked-on-this-key / candidate ──────────────────────────────────────────
# INSYNC (diff zero) and BEHIND (a readable, non-zero diff — parked ones included) feed the rollout.
cands=(); INSYNC=(); BEHIND=()
for n in $auto; do
  key="$(jq -r --arg n "$n" '.[$n] | if . == null then "" else "\(.version)/\(.schematic)" end' "$tf")"
  role="$(jq -r --arg n "$n" '.[$n].role // ""' "$tf")"
  if [ -z "$key" ]; then log "$n: auto but not in node_install_targets — nothing declared to sync to"; continue; fi
  if [ "$role" = controlplane ] && [ "$rollout_on" != true ]; then
    log "$n: declared controlplane — without the fleet rollout the reconciler never syncs a control plane (reconcile_rollout.enabled)"
    set_node "$n" parked "$key" "declared controlplane with reconcile: auto — control planes sync only through the fleet rollout (machines.yaml reconcile_rollout)" guard; continue
  fi
  for a in labels taints ephemeral_disk registered; do
    [ "$(axis "$n" "$a")" = drift ] && log "$n: $a drift — reported by the belt, not reconciled here"
  done
  r="$(axis "$n" reachable)"; v="$(axis "$n" version)"; s="$(axis "$n" schematic)"
  if [ "$r" != ok ] || [ -z "$v" ] || [ -z "$s" ]; then
    log "$n: live state unreadable (reachable=${r:-?} version=${v:-?} schematic=${s:-?}) — no action (MgmtNodeMissing owns an absent node)"
    [ -n "$(field "$n" state)" ] || set_node "$n" idle "$key" "live unreadable"
    continue
  fi
  if [ "$v" = ok ] && [ "$s" = ok ]; then
    if [ "$(field "$n" state)" = parked ]; then
      pc="$(park_cause "$n")"
      if [ "$pc" = verb-failed ] || [ "$pc" = interrupted ]; then
        # The version was never what failed: diff zero says nothing about health (FU-276).
        if ! node_verify "$n"; then
          log "$n: diff is zero but the park is $pc and node-maintenance.sh verify FAILS (or cannot read) — stays PARKED, not counted synced"
          set_node "$n" parked "$(field "$n" key)" "$pc; diff zero, health check failing since $(date -u +%FT%TZ) — read the node (node-maintenance.sh verify $n)" "$pc"
          continue
        fi
        log "$n: diff is zero AND node-maintenance.sh verify passes — clearing the $pc park on $(field "$n" key)"
      else
        log "$n: diff is zero — clearing the park on $(field "$n" key)${pc:+ ($pc)}"
      fi
    fi
    [ "$(field "$n" state)" = idle ] || log "$n: in sync at $key — idle"
    set_node "$n" idle "$key" "in sync"; INSYNC+=("$n"); continue
  fi
  BEHIND+=("$n")
  if [ "$(field "$n" state)" = parked ] && [ "$(field "$n" key)" = "$key" ]; then
    log "$n: PARKED on $key ($(field "$n" reason)) — not retried; a new declared key or a human clears it"; continue
  fi
  log "$n: install diff (version=$v schematic=$s) → declared $key"
  cands+=("$n")
done

# ── 6R. the fleet rollout (switch ON) — decides PICK, the one node this tick may sync ───────────
ro()      { jq -r "$@" <<<"$RO"; }
ro_set()  { RO="$(jq -c "$@" <<<"$RO")"; }
ro_node() { jq -r --arg n "$1" --arg f "$2" '.nodes[$n][$f] // "" | tostring' <<<"$RO"; }
vnewest() { printf '%s\n' "$@" | sed '/^$/d' | sort -V | tail -1; }
volder()  { [ "$1" != "$2" ] && [ "$(vnewest "$1" "$2")" = "$2" ]; }   # $1 older than $2
in_list() { local x="$1" y; shift; for y; do [ "$x" = "$y" ] && return 0; done; return 1; }

# The ranking: `node-maintenance.sh order`'s own rows (ORDER_FORMAT=tsv) — least risky first, and
# its GARAGE/LH columns are the storage half of a node's TYPE. Never re-derived here.
RANKED=(); declare -A STOR=()
load_rank() {
  local out risk node dv solo quorum garage lh
  if [ -n "${RECONCILE_ORDER_CMD:-}" ]; then out="$($RECONCILE_ORDER_CMD)" || return 1
  else out="$(cd "$REPO" && INSTALL_TARGETS="$tf" ORDER_FORMAT=tsv devbox run --quiet -- bash scripts/node-maintenance.sh order 2>/dev/null)" || return 1; fi
  [ -n "$out" ] || return 1
  while IFS=$'\t' read -r risk node dv solo quorum garage lh; do
    [ -n "$node" ] || continue
    RANKED+=("$node")
    if [ "$garage" = yes ] || { [ "${lh:-0}" -gt 0 ] 2>/dev/null; }; then STOR[$node]=storage; else STOR[$node]=compute; fi
  done <<<"$out"
  [ ${#RANKED[@]} -gt 0 ]
}
rank_sort() {  # <node...> → the same nodes, least risky first; any the ranking lacks go last
  local r x
  for r in "${RANKED[@]}"; do for x in "$@"; do [ "$x" = "$r" ] && echo "$x"; done; done
  for x in "$@"; do in_list "$x" "${RANKED[@]}" || echo "$x"; done
}
type_of() {  # class × role × schematic × storage — what one canary stands for
  printf '%s/%s/%s/%s' "$(decl "$1" class)" "$(decl "$1" role)" "$(decl "$1" schematic | cut -c1-8)" "${STOR[$1]:-compute}"
}
# mgmt-rollout-evidence.sh (FU-273's C2): 0 exercised, 1 not yet, 2 cannot tell (= not yet). A
# missing script reads "not yet" everywhere — logged once per rollout; the timeout ends the stage.
evidence() {  # <node> <since>
  if [ ! -f "$EVIDENCE" ]; then
    [ "$(ro '.evidence_missing // false')" = true ] || {
      log "rollout: $EVIDENCE does not exist — every canary reads 'not yet'; the canary stage ends on its timeout"
      ro_set '.evidence_missing = true'; }
    return 1
  fi
  local rc=0
  if [ -n "${RECONCILE_EVIDENCE:-}" ]; then bash "$EVIDENCE" "$1" "$2" || rc=$?
  else ( cd "$REPO" && devbox run --quiet -- bash "$EVIDENCE" "$1" "$2" ) || rc=$?; fi
  [ "$rc" = 0 ]
}
# How many MgmtRolloutDifferential alerts fire (C2's detector); a non-zero exit = unreadable.
differential() {
  if [ -n "${RECONCILE_DIFFERENTIAL_CMD:-}" ]; then $RECONCILE_DIFFERENTIAL_CMD; return; fi
  local r; r="$(curl -sS --max-time 15 --data-urlencode 'query=ALERTS{alertname="MgmtRolloutDifferential",alertstate="firing"}' "$PROM/api/v1/query")" || return 1
  jq -e '.status == "success"' >/dev/null 2>&1 <<<"$r" || return 1
  jq -r '.data.result | length' <<<"$r"
}
# ── FU-278: the workload-health hold ────────────────────────────────────────────────────────────
# The READ is node-maintenance.sh's (generic, no service named); the baseline and the rule are here.
wh_read() {  # → every workload as ONE JSON array; non-zero = unreadable (never an empty "all fine")
  local out
  if [ -n "${RECONCILE_WORKLOAD_HEALTH_CMD:-}" ]; then out="$($RECONCILE_WORKLOAD_HEALTH_CMD)" || return 1
  else out="$(cd "$REPO" && devbox run --quiet -- bash scripts/node-maintenance.sh workload-health 2>/dev/null)" || return 1; fi
  jq -se 'length > 0 and all(.[]; (.key | type) == "string" and (.healthy | type) == "boolean")' >/dev/null 2>&1 <<<"$out" || return 1
  jq -sc . <<<"$out"
}
wh_snapshot() {  # the rollout-start baseline; unreadable leaves it unset, and the gate holds until one is taken
  local cur
  if ! cur="$(wh_read)"; then log "rollout: workload-health baseline UNREADABLE — held until one can be taken"; return 1; fi
  ro_set --argjson c "$cur" --argjson t "$(now)" \
    '.wh.baseline = ($c | map({key: .key, value: {healthy, revision}}) | from_entries) | .wh.baseline_at = $t'
  log "rollout: workload-health baseline — $(jq -r length <<<"$cur") workloads, $(jq -r 'map(select(.healthy | not)) | length' <<<"$cur") already unhealthy (those never hold$(jq -r 'map(select(.healthy | not) | .key) | if length > 0 then ": " + join(", ") else "" end' <<<"$cur"))"
}
# The rule, against the baseline. Sets WH_WHY ("" | workload-health | workload-health-unreadable) and
# records the held set in rollout.json (.wh.held — what the log, the pending reasons and the
# mgmt_reconcile_rollout_workload_held series name). A human ack (WH_ACK) adds everything held at
# that moment to .wh.acked for the rest of this rollout.
WH_WHY=""
wh_gate() {
  local cur ev held logged k c r rv
  WH_WHY=""
  if [ "$(ro '.wh.baseline | type')" != object ]; then
    wh_snapshot || { ro_set '.wh.held = []'; WH_WHY=workload-health-unreadable; return 0; }
  fi
  if ! cur="$(wh_read)"; then
    ro_set '.wh.held = []'; WH_WHY=workload-health-unreadable
    log "rollout: the workload-health read is UNREADABLE — held (an unreadable read is a hold)"; return 0
  fi
  ev="$(jq -c --argjson b "$(ro -c '.wh.baseline')" --argjson a "$(ro -c '.wh.acked // []')" '
    [ .[] | select(.healthy | not) | . as $w | ($b[$w.key] // null) as $s
      | select($s == null or $s.healthy == true)        # already unhealthy at the snapshot: never holds (not `// true`: false is falsy)
      | select(($a | index($w.key)) == null)            # acknowledged by a human for this rollout
      | . + { snap_revision: ($s.revision // null),
              verdict: (if .class == "platform" then "hold"
                        elif .class == "stack-important" and $s != null and $s.revision == .revision then "hold"
                        else "log" end) } ]' <<<"$cur")"
  held="$(jq -c 'map(select(.verdict == "hold") | {key, class, revision, since, reason})' <<<"$ev")"
  if [ -e "$WH_ACK" ]; then
    if [ "$held" != '[]' ]; then
      ro_set --argjson h "$held" '.wh.acked = ((.wh.acked // []) + ($h | map(.key)) | unique)'
      log "rollout: workload-health hold ACKED by a human ($WH_ACK) — $(jq -r 'map(.key) | join(", ")' <<<"$held") no longer hold this rollout"
      held='[]'
    else log "rollout: $WH_ACK present but nothing is held — ignored"; fi
    rm -f "$WH_ACK"
  fi
  # Log-only verdicts: once per workload and revision, not every tick.
  while IFS=$'\t' read -r k c rv r; do
    [ -n "$k" ] || continue
    [ "$(ro --arg k "$k" '.wh.logged[$k] // ""')" = "$rv" ] && continue
    log "rollout: $k ($c) unhealthy on revision $rv — logged, not held ($([ "$c" = stack-singleton ] && echo "a stack singleton" || echo "a new revision since the snapshot: the stack's own change")): $r"
    ro_set --arg k "$k" --arg rv "$rv" '.wh.logged[$k] = $rv'
  done < <(jq -r '.[] | select(.verdict == "log") | [.key, .class, .revision, .reason] | @tsv' <<<"$ev")
  ro_set --argjson h "$held" '.wh.held = $h'
  [ "$held" = '[]' ] || WH_WHY=workload-health
}
wh_names() { ro -r '[.wh.held[]? | "\(.key)@\(.revision) (\(.class), unhealthy since \(.since): \(.reason))"] | join("; ")'; }

set_stage() {  # <stage>
  [ "$(ro .stage)" = "$1" ] && return 0
  ro_set --arg s "$1" --argjson t "$(now)" '.stage = $s | .stage_since = $t'
}
rollout_start() {  # <target>
  local t="$1" prev="" kind=forward stage=canary prior='[]'
  [ -n "$RO" ] && prev="$(ro .target)"
  if [ -n "$prev" ] && volder "$t" "$prev"; then
    # A declared target OLDER than the last rollout's is a human revert commit: no canary (the
    # version ran before), never halted by the differential (that is what asked for it), and the
    # nodes the last rollout moved go back first.
    kind=revert; stage=fleet; prior="$(ro -c '[.nodes | keys[]]')"
  elif [ "$prev" = "$t" ]; then
    stage=fleet   # the same target as the last rollout (its deferred nodes, a cleared park): canaries proved it
  fi
  RO="$(jq -nc --arg t "$t" --arg k "$kind" --arg s "$stage" --arg p "$prev" --argjson pr "$prior" --argjson now "$(now)" \
    '{target:$t, kind:$k, stage:$s, started_at:$now, stage_since:$now, prev_target:$p, prior:$pr,
      canaries:{}, canaries_picked:false, evidence:{}, canary_wait_started:0, canary_timed_out:false,
      halt_reason:"", halted_from:"", nodes:{}, superseded:[],
      wh:{baseline:null, baseline_at:0, acked:[], logged:{}, held:[]}}')"
  log "rollout: START $t ($kind) — stage $stage${prev:+ (previous rollout: $prev)}"
  # FU-278: the workload-health baseline, before the first window. Not on a revert (never held).
  [ "$kind" = revert ] || wh_snapshot || true
}
rollout_supersede() {  # <newer target>
  local old; old="$(ro .target)"
  log "rollout: SUPERSEDED $old → $1 — the not-yet nodes skip $old; those already on it get $1 in the next rollout; back to the canary stage"
  ro_set --arg t "$1" --arg o "$old" --argjson now "$(now)" \
    '.superseded += [{from:$o, to:$t, at:$now}] | .target = $t | .kind = "forward" | .stage = "canary" | .stage_since = $now
     | .canaries = {} | .canaries_picked = false | .evidence = {} | .canary_wait_started = 0 | .canary_timed_out = false
     | .halt_reason = "" | .halted_from = ""'
}
rollout_done() {  # <why>
  [ "$(ro .stage)" = done ] && return 0
  set_stage done; log "rollout: $(ro .target) DONE — $1"
}
pick_canaries() {  # <target> <work node...> — one per non-CP type, the least risky of each
  local t="$1" n m c ty insync_t=(); shift
  declare -A seen=()
  for n in "${INSYNC[@]}"; do [ "$(decl "$n" version)" = "$t" ] && insync_t+=("$n"); done
  for n in $(rank_sort "$@"); do
    [ "$(decl "$n" role)" = controlplane ] && continue   # CPs go last; the CP verb's post-check is their predicate
    ty="$(type_of "$n")"; [ -n "${seen[$ty]:-}" ] && continue; seen[$ty]=1
    c="$n"
    # A member of this type ALREADY on the target (the tofu canary override) is the canary: it has
    # been carrying the new version, so the stage waits on its evidence instead of a second sync.
    for m in $(rank_sort "${insync_t[@]}"); do [ "$(type_of "$m")" = "$ty" ] && { c="$m"; break; }; done
    ro_set --arg ty "$ty" --arg c "$c" '.canaries[$ty] = $c'
    if [ "$c" != "$n" ]; then
      ro_set --arg c "$c" --arg t "$t" '.nodes[$c] = {target:$t, synced_at:.started_at, already:true}'
      log "rollout: canary for $ty is $c (already on $t)"
    else log "rollout: canary for $ty is $c"; fi
  done
  ro_set '.canaries_picked = true'
}

halt_release() {  # <why> → what releases it, for the pending reasons
  case "$1" in
    differential|unreadable) echo "resumes when MgmtRolloutDifferential clears" ;;
    workload-health) echo "held on $(wh_names) — resumes when they are healthy again, or on an ack (touch $WH_ACK)" ;;
    workload-health-unreadable) echo "the workload-health read (node-maintenance.sh workload-health) failed — resumes when it reads" ;;
  esac
}
halt_rollout() {  # <target> <why> — stage halted, the reason recorded + logged, the pressure lifted
  local T="$1" why="$2" msg
  case "$why" in
    differential) msg="MgmtRolloutDifferential is firing" ;;
    unreadable) msg="MgmtRolloutDifferential is unreadable (an unreadable gate is a no)" ;;
    workload-health) msg="HELD on workload health (FU-278; never a revert): $(wh_names)" ;;
    workload-health-unreadable) msg="the workload-health read failed (an unreadable read is a hold)" ;;
  esac
  if [ "$(ro .stage)" != halted ]; then
    ro_set --arg s "$(ro .stage)" '.halted_from = $s'
    log "rollout: $T HALTED — $msg; no sync starts, pressure lifted"
  elif [ "$(ro .halt_reason)" != "$why" ] || [ "${why#workload-health}" != "$why" ]; then
    log "rollout: $T still halted — $msg"
  fi
  set_stage halted; ro_set --arg w "$why" '.halt_reason = $w'
  reconcile_taints "$T"   # no node listed: while the fleet looks worse, push no more work onto it
}

PICK=""
rollout_plan() {
  local T c n work=() behind_t=() pend=() waiting=() ordered=() workers=() cps=() since ws f frc why
  if [ ${#cands[@]} -eq 0 ]; then
    if [ -n "$RO" ]; then rollout_done "no node of the rollout is left to sync"; reconcile_taints "$(ro .target)"; fi
    return 0
  fi
  # ── the target: one rollout at a time; a newer declaration supersedes, an older one is a revert
  T="$(vnewest $(for c in "${cands[@]}"; do decl "$c" version; echo; done))"
  if [ -z "$RO" ] || [ "$(ro .stage)" = done ]; then rollout_start "$T"
  elif [ "$(ro .target)" != "$T" ]; then
    if volder "$T" "$(ro .target)"; then rollout_start "$T"; else rollout_supersede "$T"; fi
  fi
  for c in "${cands[@]}"; do
    if [ "$(decl "$c" version)" != "$T" ]; then
      set_node "$c" pending "$(keyof "$c")" "waits for the $T rollout to finish (one rollout at a time)"
    elif [ -n "$(ro_node "$c" target)" ] && [ "$(ro_node "$c" target)" != "$T" ]; then
      set_node "$c" pending "$(keyof "$c")" "synced to $(ro_node "$c" target) earlier in this rollout — gets $T in the next one"
    else work+=("$c"); fi
  done
  for n in "${BEHIND[@]}"; do [ "$(decl "$n" version)" = "$T" ] && behind_t+=("$n"); done
  if [ ${#work[@]} -eq 0 ]; then rollout_done "every node of $T is synced or parked"; reconcile_taints "$T"; return 0; fi

  # ── the halt: MgmtRolloutDifferential, then the workload-health hold (FU-278) — neither on a
  # revert (the differential is why it exists; the revert is the fix)
  if [ "$(ro .kind)" != revert ]; then
    frc=0; f="$(differential)" || frc=$?; why=""
    if [ "$frc" != 0 ] || ! [[ "$f" =~ ^[0-9]+$ ]]; then why=unreadable
    elif [ "$f" -gt 0 ]; then why=differential; fi
    if [ -z "$why" ]; then wh_gate; why="$WH_WHY"; fi
    if [ -n "$why" ]; then
      halt_rollout "$T" "$why"
      for c in "${work[@]}"; do set_node "$c" pending "$(keyof "$c")" "rollout $T halted ($why) — $(halt_release "$why")"; done
      return 0
    fi
    if [ "$(ro .stage)" = halted ]; then
      log "rollout: $T RESUMED — MgmtRolloutDifferential clear and no workload held; back to $(ro .halted_from)"
      set_stage "$(ro .halted_from)"; ro_set '.halt_reason = ""'
    fi
  fi
  reconcile_taints "$T" "${behind_t[@]}"

  if ! load_rank; then
    for c in "${work[@]}"; do set_node "$c" pending "$(keyof "$c")" "the fleet ranking is unreadable (node-maintenance.sh order) — refusing (an unreadable gate is a no)"; done
    log "rollout: cannot rank the fleet — no sync this tick"; return 0
  fi

  # ── stage 1: canaries — synced one per tick, then evidence for every one, or the timeout
  if [ "$(ro .stage)" = canary ]; then
    [ "$(ro .canaries_picked)" = true ] || pick_canaries "$T" "${work[@]}"
    for c in $(rank_sort $(ro '.canaries[]')); do in_list "$c" "${work[@]}" && pend+=("$c"); done
    if [ ${#pend[@]} -gt 0 ]; then
      PICK="${pend[0]}"
      for c in "${work[@]}"; do [ "$c" = "$PICK" ] || set_node "$c" pending "$(keyof "$c")" "canary stage of $T: queued behind the canary $PICK"; done
      return 0
    fi
    ws="$(ro .canary_wait_started)"
    if [ "$ws" = 0 ]; then
      ws="$(ro '. as $r | [.canaries[] | $r.nodes[.].synced_at // empty] | max // empty')"; [ -n "$ws" ] || ws="$(now)"
      ro_set --argjson w "$ws" '.canary_wait_started = $w'
      log "rollout: every canary of $T synced — waiting for evidence (timeout ${CANARY_TIMEOUT}s)"
    fi
    for c in $(ro '.canaries[]'); do
      [ "$(ro --arg c "$c" '.evidence[$c] // ""')" = "" ] || continue
      since="$(ro_node "$c" synced_at)"; [ -n "$since" ] || since="$(ro .started_at)"
      if evidence "$c" "$since"; then
        ro_set --arg c "$c" --argjson t "$(now)" '.evidence[$c] = $t'; log "rollout: canary $c EXERCISED on $T"
      else waiting+=("$c"); fi
    done
    if [ ${#waiting[@]} -eq 0 ]; then
      log "rollout: canary stage of $T passed — every canary exercised"; set_stage fleet
    elif [ $(( $(now) - ws )) -ge "$CANARY_TIMEOUT" ]; then
      log "rollout: canary evidence TIMED OUT after ${CANARY_TIMEOUT}s (no evidence: ${waiting[*]}) — advancing anyway (default forward; MgmtRolloutCanaryTimedOut)"
      ro_set '.canary_timed_out = true'; set_stage fleet
    else
      for c in "${work[@]}"; do set_node "$c" pending "$(keyof "$c")" "canary stage of $T: waiting for evidence on ${waiting[*]} ($(( ws + CANARY_TIMEOUT - $(now) ))s to the timeout)"; done
      return 0
    fi
  fi

  # ── stage 2: the fleet — ranked, workers first, control planes last and one at a time
  if [ "$(ro .kind)" = revert ]; then
    for c in $(rank_sort "${work[@]}"); do in_list "$c" $(ro '.prior[]') && ordered+=("$c"); done
    for c in $(rank_sort "${work[@]}"); do in_list "$c" $(ro '.prior[]') || ordered+=("$c"); done
  else
    mapfile -t ordered < <(rank_sort "${work[@]}")
  fi
  for c in "${ordered[@]}"; do if [ "$(decl "$c" role)" = controlplane ]; then cps+=("$c"); else workers+=("$c"); fi; done
  PICK="${workers[0]:-${cps[0]}}"
  for c in "${ordered[@]}"; do
    [ "$c" = "$PICK" ] && continue
    if [ "$(decl "$c" role)" = controlplane ] && [ ${#workers[@]} -gt 0 ]; then
      set_node "$c" pending "$(keyof "$c")" "control planes go last — ${#workers[@]} worker(s) of $T first"
    else set_node "$c" pending "$(keyof "$c")" "queued behind $PICK (WIP 1)"; fi
  done
}

# ── 6. WIP 1: at most one sync per tick, the rest queue ─────────────────────────────────────────
if [ "$rollout_on" = true ]; then
  rollout_plan
  if [ -z "$PICK" ]; then save; emit stamp; log "tick done — nothing to sync"; exit 0; fi
  n="$PICK"; key="$(keyof "$n")"
else
  if [ ${#cands[@]} -eq 0 ]; then save; emit stamp; log "tick done — nothing to sync"; exit 0; fi
  n="${cands[0]}"; key="$(jq -r --arg n "$n" '.[$n] | "\(.version)/\(.schematic)"' "$tf")"
  for q in "${cands[@]:1}"; do set_node "$q" pending "$(jq -r --arg n "$q" '.[$n] | "\(.version)/\(.schematic)"' "$tf")" "queued behind $n (WIP 1)"; done
fi

# Every live declared window is someone else's: the check runs before the verb opens ours. A
# seat's window on the target blocks too (hands-on work there must not get a sync on top) —
# unless the seat opened it with --admit-reconciler, which is the attended-sync case.
if [ -n "${RECONCILE_WINDOWS_JSON:-}" ]; then wj="$(cat "$RECONCILE_WINDOWS_JSON")"
else
  kc="${KUBECONFIG:-}"; [ -f "$kc" ] || kc=/var/lib/mgmt/kubeconfig
  if cm="$(cd "$REPO" && devbox run --quiet -- kubectl --kubeconfig "$kc" -n agent-coordinator get cm responder-window -o json 2>&1)"; then
    wj="$(jq -c --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[(.data // {}) | to_entries[] | (.value | fromjson?) // empty | select((.until // "") > $now)]' <<<"$cm")" || wj=""
  elif grep -q NotFound <<<"$cm"; then wj='[]'
  else wj=""; fi
fi
if [ -z "$wj" ]; then
  set_node "$n" pending "$key" "declared windows unreadable — refusing (an unreadable gate is a no)"
  save; emit stamp; log "$n: cannot read the declared-window record — not opening a window"; exit 0
fi
other="$(jq -r --arg n "$n" '[.[] | select((.node // "") != $n or (.admit_reconciler // false) != true) | "\(.id) (\(.by // "?"))"] | join(", ")' <<<"$wj")"
if [ -n "$other" ]; then
  set_node "$n" pending "$key" "another window is open: $other"
  save; emit stamp; log "$n: WIP 1 — a declared window is open ($other); retry next tick"; exit 0
fi

# ── 7. the sync: the verb, once ─────────────────────────────────────────────────────────────────
# A control plane (reachable only with the rollout on) goes through controlplane-upgrade.sh, which
# wraps the same verb in etcd quorum + snapshot + the cilium gate and keeps its 2/4/1 contract.
if [ "$(decl "$n" role)" = controlplane ]; then verb=controlplane-upgrade.sh; else verb="node-maintenance.sh upgrade"; fi
set_node "$n" syncing "$key" "$verb"; save; emit stamp
log "$n: SYNC → $key — $verb (its own preflight, floors, drain, install, verify)"
rc=0
if [ "$verb" = controlplane-upgrade.sh ]; then
  if [ -n "${RECONCILE_CP_VERB:-}" ]; then $RECONCILE_CP_VERB "$n" || rc=$?
  else ( cd "$REPO" && devbox run --quiet -- bash scripts/controlplane-upgrade.sh "$n" ) || rc=$?; fi
elif [ -n "${RECONCILE_VERB:-}" ]; then $RECONCILE_VERB upgrade "$n" || rc=$?
else ( cd "$REPO" && devbox run --quiet -- bash scripts/node-maintenance.sh upgrade "$n" ) || rc=$?; fi
case "$rc" in
  0)
    # Completion is the DIFF, not the verb's word: re-read this node the same way the tick did.
    jq -c --arg n "$n" '{($n): .[$n]}' "$tf" >"$tf.auto"; : >"$df"
    if diff_nodes "$tf.auto" "$df" && [ "$(axis "$n" version)" = ok ] && [ "$(axis "$n" schematic)" = ok ]; then
      set_node "$n" idle "$key" "synced $(date -u +%FT%TZ)"; log "$n: SYNCED — diff zero at $key"
      if [ "$rollout_on" = true ] && [ -n "$RO" ]; then
        # The rollout's record of this node, and its pressure lifted now rather than next tick.
        ro_set --arg n "$n" --arg t "$(decl "$n" version)" --argjson s "$(now)" '.nodes[$n] = {target:$t, synced_at:$s}'
        kube taint node "$n" "$TAINT_KEY-" >/dev/null 2>&1 && log "pressure: $n — $TAINT_KEY removed (synced)"
      fi
    else
      set_node "$n" parked "$key" "verb exited 0 but the diff is not zero (version=$(axis "$n" version) schematic=$(axis "$n" schematic))" diff-disagrees
      log "$n: PARKED — the verb said done, the diff disagrees"
    fi ;;
  4)
    set_node "$n" parked "$key" "the declared version path is impossible (verb exit 4: a cross-minor downgrade or a skipped minor) — across a minor Talos rolls back only via talosctl rollback (while the fallback entry exists, i.e. shortly after the upgrade reboot) or a reinstall; fix the declaration or roll back by hand" impossible
    log "$n: PARKED — the declared path is impossible (exit 4); retrying cannot fix it" ;;
  2)
    set_node "$n" pending "$key" "refused by a gate (verb exit 2, nothing touched) — retried next tick"
    log "$n: refused by a gate (exit 2) — nothing touched, retried next tick" ;;
  *)
    set_node "$n" parked "$key" "verb exited $rc — the one attempt for this key is spent; read the journal. Clears on a new key, or once diff zero AND node-maintenance.sh verify passes" verb-failed
    log "$n: PARKED — verb exited $rc (journalctl -u mgmt-reconcile)"
    close_verb_window "$n" ;;
esac
# FU-278: the window has returned — read the workloads now, not only before the next window, so a
# hold is on record (and the pressure off) the moment a window left something broken behind it.
if [ "$rollout_on" = true ] && [ -n "$RO" ] && [ "$(ro .kind)" != revert ] && [ "$(ro .stage)" != done ] && [ "$(ro .stage)" != halted ]; then
  wh_gate
  [ -z "$WH_WHY" ] || halt_rollout "$(ro .target)" "$WH_WHY"
fi
save; emit stamp; log "tick done"
exit 0
