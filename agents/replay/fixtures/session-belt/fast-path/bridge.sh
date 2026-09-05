# ── bridge ── the scan state the fast path reads. stacks_json is the ONE stack source
# (cluster-merged in production); HERE anchors the latch-script path. This fixture's PR is
# WORKER-authored, so the latch is REACHED and must pass (exit 0) — unlike the author guard
# fixture, whose shim PROBE-FAILs to prove the guard settles first.
HERE="$REPLAY_FIXTURE"
KUBECTL=kubectl
KUBE=""
LOOP_NS="circles-agents"
REPO_MAX_WIP=3   # the scan's own default (top of the file) — the fast path compares flive against it
stacks_json() {
  cat <<'JSON'
{ "stacks": [ { "name": "circles", "graduated": true, "coordinatorEnabled": true,
  "mainRepo": "circles", "repos": ["circles-iac", "circles"] } ] }
JSON
}

# ── stub ── item_class_push is defined in the item-class block; the unit-fast-path block calls it
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}
