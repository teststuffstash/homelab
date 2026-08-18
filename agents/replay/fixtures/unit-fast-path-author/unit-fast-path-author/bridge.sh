# ── bridge ── the scan state the fast path reads. stacks_json is the ONE stack source
# (cluster-merged in production); HERE anchors the latch-script path the guarded row must never
# reach — it points at a PROBE-FAIL shim so an execution past the author guard is loud, not
# silently absorbed by a fail-open latch.
HERE="$REPLAY_FIXTURE"
KUBECTL=kubectl
KUBE=""
LOOP_NS="circles-agents"
stacks_json() {
  cat <<'JSON'
{ "stacks": [ { "name": "circles", "graduated": true, "coordinatorEnabled": true,
  "mainRepo": "circles", "repos": ["circles-iac", "circles"] } ] }
JSON
}
