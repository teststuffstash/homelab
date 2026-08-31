# ── bridge ── the scan state the fast path reads. stacks_json is the ONE stack source
# (cluster-merged in production); HERE anchors the latch-script path.
HERE="$REPLAY_FIXTURE"
KUBECTL=kubectl
KUBE=""
LOOP_NS="circles-agents"
REPO_MAX_WIP=3
stacks_json() {
  cat <<'JSON'
{ "stacks": [ { "name": "circles", "graduated": true, "coordinatorEnabled": true,
  "mainRepo": "circles", "repos": ["circles-iac", "circles"] } ] }
JSON
}
# Stubs for functions called by the fast path that are defined outside the block.
dispatch_phase() { :; }
scan_phase() { :; }