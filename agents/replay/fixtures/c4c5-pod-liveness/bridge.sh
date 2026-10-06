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
# PODS and PODS_ESCAPED are now bound inside the sentinel region (coordinator-scan.sh),
# not in the bridge. The sentinel reads from the kubectl world stub directly.
# KUBECTL is the path to the kubectl stub, KUBE are kubectl flags (empty in fixtures).
KUBECTL="kubectl"
KUBE=""
ITEM_CLASS_ROWS=""
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
