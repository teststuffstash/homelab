# ── bridge ── the scan state the fast path reads. stacks_json is the ONE stack source
# (cluster-merged in production); HERE anchors the latch-script path the guarded row must never
# reach — it points at a PROBE-FAIL shim so an execution past the goal-head guard is loud, not
# silently absorbed by a fail-open latch.
HERE="$REPLAY_FIXTURE"
KUBECTL=kubectl
KUBE=""
LOOP_NS="oracle-fleet-agents"
stacks_json() {
  cat <<'JSON'
{ "stacks": [ { "name": "oracle-fleet", "graduated": true, "coordinatorEnabled": true,
  "mainRepo": "oracle-fleet", "repos": ["oracle-fleet", "oracle-fleet-iac"] } ] }
JSON
}

# ── stub ── item_class_push is defined in the item-class block; the unit-fast-path block calls it
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}