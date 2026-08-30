# ── bridge ── launcher state common to every strike-classifier row. Each row's varying
# state (STATS, runlog content, kubectl pod response) is sourced from $REPLAY_WORLD/vars.sh
# (the row's rows/<id>/vars.sh overlay) and world files (runlog.txt, kubectl/ files).
KUBECTL="kubectl"
KUBE=""
NS="test-namespace"
POD="test-pod-xyz"
RUNLOG="$REPLAY_WORLD/runlog.txt"
STRUCK_MODEL="claude/opus-5"
ROUND="1"
REPLAY_ACTIONS="${REPLAY_ACTIONS:-/dev/null}"
# PR_URL is the #866 axis: empty = PR-less ride (every pre-existing row), non-empty = a fix round
# on an open PR. Declared here so a row can override it in its vars.sh overlay.
PR_URL=""
# Per-row vars (STATS, etc.) — row overlay on $REPLAY_WORLD
. "$REPLAY_WORLD/vars.sh"