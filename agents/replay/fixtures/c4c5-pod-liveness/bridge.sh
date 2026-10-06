# ── bridge ── per-repo loop variables for the C4/C5 selector test: one issue with a live pod,
# one without. Tests that per-issue liveness is checked in the selector, not repo-wide gate.
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
# PODS from the kubectl stub (get-pods.json has issue-100's pod)
PODS="agent-session-homelab-issue-100-r1"
# Escape PODS for jq (will be passed as $PODS_ESCAPED to the selector)
PODS_ESCAPED="$(printf '%s\n' "$PODS" | sed 's/[\\"\x27]/\\&/g')"
ITEM_CLASS_ROWS=""
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
