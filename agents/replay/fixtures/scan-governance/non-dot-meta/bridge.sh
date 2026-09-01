# ── bridge ── same scan state as the sibling fixtures. `GOVERNANCE_LINT` is set through the
# override the shipped script already declares, pointing at the custom governance-lint.sh in
# this fixture directory.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
GUARDED_REPO="${GUARDED_REPO:-homelab}"
orphans=""