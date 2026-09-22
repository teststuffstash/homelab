#!/usr/bin/env bash
# mgmt-reconcile — the management box's NODE reconciler (ADR-132 §MB4 layers 3–5,
# docs/management-box.md §MB4). For every node `machines/machines.yaml` declares `reconcile: auto`,
# it compares the DECLARED install (node_install_targets from main's applied state — the same
# expression the upgrade verb passes as --image) with LIVE (mgmt-probe.sh's own node diff, run for
# those nodes only), and when the version or schematic axis differs it runs the existing verb:
# `node-maintenance.sh upgrade <node>`. It adds only what the verb does not know:
#
#   WIP 1        one sync per tick and the unit is a oneshot, so one window at a time by
#                construction; ANY live declared window (agents/seat-window.sh's record) refuses
#                the tick — on another node, seat-wide, or on the target itself — unless it is on
#                the target AND was opened with --admit-reconciler (the attended canary). The
#                check runs BEFORE the verb opens its own window, so a window on the target at
#                that moment is always someone else's. The verb's own WIP 1 (no other node cordoned or
#                NotReady) and its fleet floors (Longhorn degraded, Garage cluster_healthy, CNPG
#                instances) stay the verb's — they are not re-implemented here.
#   one attempt  keyed on the DECLARED target (version/schematic). A verb exit 2 is a REFUSAL
#                (a gate said no, nothing was touched) and is retried on the next tick; any other
#                non-zero exit — or a zero exit that leaves the diff non-zero, or a sync the loop
#                died in the middle of — PARKS the node on that key. A parked node is never retried
#                for the same key: a bad disk must not become a reinstall loop. A NEW declared key
#                (the next commit) un-parks it; so does the diff reaching zero by other means.
#                By hand: `rm /var/lib/mgmt/reconcile/state.json` (or edit the node's entry).
#   state        /var/lib/mgmt/reconcile/state.json on the box, surfaced as mgmt_reconcile_* through
#                the node_exporter textfile — never a commit (§MB4 layer 5).
#
# What it deliberately does NOT do: labels/taints drift is reported by the belt and left alone
# (tofu's apply path owns them — `mgmt_node_drift`, MgmtNodeLiveStateDrift); ephemeral_disk drift
# is reinstall-class (Talos never re-partitions) and stays a human window; a `manual` node's diff is
# drift on the belt and nothing else; it never runs tofu. A node whose declared role is
# controlplane is refused even if the inventory says auto (machines/generate.py refuses that too).
#
# Exit 0 = the tick evaluated (any verdict). Exit 1 = it could not read an input; nothing was run
# and last-run is not stamped, so MgmtReconcileLoopStale sees a loop that cannot look.
#
# Test seams (scripts/mgmt-reconcile-test.sh — the state machine against a fake verb):
#   RECONCILE_DIR  RECONCILE_MACHINES_JSON  RECONCILE_TARGETS_JSON  RECONCILE_WINDOWS_JSON
#   RECONCILE_DIFF_CMD "<cmd> <targets-file> <drift-out>"   RECONCILE_VERB "<cmd> upgrade <node>"
#   MGMT_TEXTFILE_DIR
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)" || exit 1
export HOME="${HOME:-/root}"
DIR="${RECONCILE_DIR:-/var/lib/mgmt/reconcile}"
STATE="$DIR/state.json"
TEXTDIR="${MGMT_TEXTFILE_DIR:-/var/lib/node-exporter-textfile}"
MAIN_STATE="${MAIN_STATE:-/var/lib/mgmt/state/main/terraform.tfstate}"
mkdir -p "$DIR" || exit 1
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
now() { date -u +%s; }

exec 9>"$DIR/.lock"; flock -n 9 || { log "another tick holds the lock — a sync is running"; exit 0; }

ST='{}'; [ -s "$STATE" ] && ST="$(jq -c . "$STATE" 2>/dev/null)" || true
[ -n "$ST" ] || { log "FATAL state file $STATE does not parse — refusing to guess (fix or remove it)"; exit 1; }
save() { local t; t="$(mktemp "$DIR/.state.XXXXXX")" && printf '%s\n' "$ST" >"$t" && mv -f "$t" "$STATE"; }
set_node() {  # <node> <state> <key> <reason>
  ST="$(jq -c --arg n "$1" --arg s "$2" --arg k "$3" --arg r "$4" --argjson t "$(now)" \
    '.[$n] = ((.[$n] // {}) + {state:$s, key:$k, reason:$r}
              + (if (.[$n].state // "") != $s then {since:$t} else {} end))' <<<"$ST")"
}
field() { jq -r --arg n "$1" --arg f "$2" '.[$n][$f] // ""' <<<"$ST"; }

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
  tmp="$(mktemp "$TEXTDIR/.mgmt_reconcile.XXXXXX")" || return 0
  printf '%s\n' "$body" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$TEXTDIR/mgmt_reconcile.prom"
}

# ── 1. a sync this loop was in the middle of when it died (box reboot, unit timeout) ─────────────
# The lock is ours, so nothing is running it any more. The attempt is spent: park, never resume —
# the node may be anywhere between cordoned and half-installed, and that is a human read.
for n in $(jq -r 'to_entries[] | select(.value.state == "syncing") | .key' <<<"$ST"); do
  log "$n: found mid-sync with no running tick — PARKED (interrupted; the attempt is spent)"
  set_node "$n" parked "$(field "$n" key)" "interrupted: the loop died mid-sync (reboot/timeout) — read the node, then clear the state"
done
save

# ── 2. the policy: reconcile:auto nodes (default manual) ─────────────────────────────────────────
if [ -n "${RECONCILE_MACHINES_JSON:-}" ]; then mj="$(cat "$RECONCILE_MACHINES_JSON")"
else mj="$(cd "$REPO" && devbox run --quiet -- yq -o=json machines/machines.yaml 2>/dev/null)"; fi
auto="$(jq -r '.machines[] | select(.reconcile == "auto") | .name' <<<"$mj" 2>/dev/null)" \
  || { log "FATAL machines/machines.yaml unreadable — no tick"; emit; exit 1; }
# A node that left `auto` (or the inventory) leaves the state and the metrics with it.
ST="$(jq -c --argjson keep "$(printf '%s\n' "$auto" | jq -R . | jq -sc 'map(select(length > 0))')" \
      'with_entries(select(.key as $k | $keep | index($k)))' <<<"$ST")"
if [ -z "$auto" ]; then log "no node declares reconcile: auto — nothing to reconcile"; save; emit stamp; exit 0; fi
log "reconcile:auto — $(tr '\n' ' ' <<<"$auto")"

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
cands=()
for n in $auto; do
  key="$(jq -r --arg n "$n" '.[$n] | if . == null then "" else "\(.version)/\(.schematic)" end' "$tf")"
  role="$(jq -r --arg n "$n" '.[$n].role // ""' "$tf")"
  if [ -z "$key" ]; then log "$n: auto but not in node_install_targets — nothing declared to sync to"; continue; fi
  if [ "$role" = controlplane ]; then
    log "$n: declared controlplane — the reconciler never syncs a control plane (ADR-132: manual until ADR-133's CPs)"
    set_node "$n" parked "$key" "declared controlplane with reconcile: auto — fix machines.yaml"; continue
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
    [ "$(field "$n" state)" = parked ] && log "$n: diff is zero — clearing the park on $(field "$n" key)"
    [ "$(field "$n" state)" = idle ] || log "$n: in sync at $key — idle"
    set_node "$n" idle "$key" "in sync"; continue
  fi
  if [ "$(field "$n" state)" = parked ] && [ "$(field "$n" key)" = "$key" ]; then
    log "$n: PARKED on $key ($(field "$n" reason)) — not retried; a new declared key or a human clears it"; continue
  fi
  log "$n: install diff (version=$v schematic=$s) → declared $key"
  cands+=("$n")
done

# ── 6. WIP 1: at most one sync per tick, the rest queue ─────────────────────────────────────────
if [ ${#cands[@]} -eq 0 ]; then save; emit stamp; log "tick done — nothing to sync"; exit 0; fi
n="${cands[0]}"; key="$(jq -r --arg n "$n" '.[$n] | "\(.version)/\(.schematic)"' "$tf")"
for q in "${cands[@]:1}"; do set_node "$q" pending "$(jq -r --arg n "$q" '.[$n] | "\(.version)/\(.schematic)"' "$tf")" "queued behind $n (WIP 1)"; done

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
set_node "$n" syncing "$key" "node-maintenance.sh upgrade"; save; emit stamp
log "$n: SYNC → $key — node-maintenance.sh upgrade (its own preflight, floors, drain, install, verify)"
rc=0
if [ -n "${RECONCILE_VERB:-}" ]; then $RECONCILE_VERB upgrade "$n" || rc=$?
else ( cd "$REPO" && devbox run --quiet -- bash scripts/node-maintenance.sh upgrade "$n" ) || rc=$?; fi
case "$rc" in
  0)
    # Completion is the DIFF, not the verb's word: re-read this node the same way the tick did.
    jq -c --arg n "$n" '{($n): .[$n]}' "$tf" >"$tf.auto"; : >"$df"
    if diff_nodes "$tf.auto" "$df" && [ "$(axis "$n" version)" = ok ] && [ "$(axis "$n" schematic)" = ok ]; then
      set_node "$n" idle "$key" "synced $(date -u +%FT%TZ)"; log "$n: SYNCED — diff zero at $key"
    else
      set_node "$n" parked "$key" "verb exited 0 but the diff is not zero (version=$(axis "$n" version) schematic=$(axis "$n" schematic))"
      log "$n: PARKED — the verb said done, the diff disagrees"
    fi ;;
  4)
    set_node "$n" parked "$key" "the declared version path is impossible (verb exit 4: a cross-minor downgrade or a skipped minor) — across a minor Talos rolls back only via talosctl rollback or a reinstall; fix the declaration or roll back by hand"
    log "$n: PARKED — the declared path is impossible (exit 4); retrying cannot fix it" ;;
  2)
    set_node "$n" pending "$key" "refused by a gate (verb exit 2, nothing touched) — retried next tick"
    log "$n: refused by a gate (exit 2) — nothing touched, retried next tick" ;;
  *)
    set_node "$n" parked "$key" "verb exited $rc — the one attempt for this key is spent; read the journal, then clear the state"
    log "$n: PARKED — verb exited $rc (journalctl -u mgmt-reconcile)" ;;
esac
save; emit stamp; log "tick done"
exit 0
