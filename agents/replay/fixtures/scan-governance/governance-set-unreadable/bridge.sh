# ── bridge ── the scan state the governance-hold block reads.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
CLASSIFY_CODEOWNERS="${HERE}/../CODEOWNERS"
GUARDED_REPO="${GUARDED_REPO:-homelab}"
orphans=""
