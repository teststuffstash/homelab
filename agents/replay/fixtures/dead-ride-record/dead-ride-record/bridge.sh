# ── bridge ── the scan's per-repo loop state the dead-ride-record block reads. HERE points at the
# REAL agents/ dir, so the block runs the real agents/ride-ended.sh, which extracts the real
# launcher blocks from agents/agent-session.sh — nothing here is a copy of the logic under test.
HERE="$REPLAY_ROOT/agents"
repo="homelab"
dispatchable=1
SPAWN=1
KUBECTL="kubectl"
KUBE=""
export GH_TOKEN="stub-token"
