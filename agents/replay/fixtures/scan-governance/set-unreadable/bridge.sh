# ── bridge ── same scan state as the sibling fixture (`HERE`, the scan's own `footprint.sh`
# source line, `orphans`). Only `GOVERNANCE_LINT` differs, and it is set through the override the
# shipped script already declares — the fixture changes the WORLD, never the clause.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
GUARDED_REPO="${GUARDED_REPO:-homelab}"
orphans=""