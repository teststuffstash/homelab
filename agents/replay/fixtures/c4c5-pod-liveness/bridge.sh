# ── bridge ── per-repo loop variables for the C4/C5 selector test with per-issue liveness.
# Sets up the world-specific data. The replay harness will load world-specific files to test
# the selector with different combinations of live pods and phantom issues.
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
c6g_nums=""
goalbased_nums=""
c4c5_cleared=""
orphans=""
units=""
resumable_branches=""
BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies.json")"
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
db=""
sess_nums=""
cg=""
gb=""
infeas_done=""
c6db_nums=""
# Read PODS from the kubectl stub. For worlds where the probe fails, this will be empty/error.
pods_json="$(cat "$REPLAY_WORLD/kubectl/get-pods.json" 2>/dev/null)"
if jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pods_json"; then
  # Valid JSON - extract pod names from the response
  PODS="$(jq -r '.items[]?.metadata.name // empty' <<<"$pods_json")"
else
  # Invalid JSON or error output - simulate probe failure
  PODS=""
fi
# Escape PODS for safe use in jq (same as in coordinator-scan.sh line 4219)
PODS_ESCAPED="$(printf '%s\n' "$PODS" | sed 's/[\\"\x27]/\\&/g')"
ITEM_CLASS_ROWS=""
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
