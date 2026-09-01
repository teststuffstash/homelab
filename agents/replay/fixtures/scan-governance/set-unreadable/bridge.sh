# ── bridge ── same scan state as the sibling fixture (`HERE`, the scan's own `footprint.sh`
# source line, `orphans`). `CLASSIFY_CODEOWNERS` is set through the env override the shipped
# script already declares — the fixture changes the WORLD, never the clause.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
# classify_touches() reads CODEOWNERS at runtime. The fixture overrides CLASSIFY_CODEOWNERS
# via env to test the unreadable-CODEOWNERS branch.
GUARDED_REPO="${GUARDED_REPO:-homelab}"
orphans=""