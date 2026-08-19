# ── bridge ── launcher state for the raw-log fallback classifier. The block reads the pod's
# status.reason via kubectl and greps RUNLOG for quota patterns. These defaults set up the test:
# the classifier should parse a runlog with quota patterns and emit ERR_CLASS=quota.
KUBECTL="kubectl"
KUBE=""
NS="test-namespace"
POD="test-pod-xyz"
RUNLOG="$REPLAY_WORLD/runlog.txt"
STRUCK_MODEL="claude/opus-5"
ROUND="1"
REPLAY_ACTIONS="${REPLAY_ACTIONS:-/dev/null}"
