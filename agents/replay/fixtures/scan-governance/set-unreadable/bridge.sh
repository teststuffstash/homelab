# ── bridge ── same scan state as the sibling fixture (`HERE`, the scan's own `footprint.sh`
# source line, `orphans`). BOTH probe paths — `CLASSIFY_CODEOWNERS` and `GOVERNANCE_LINT` — are
# broken through the env overrides the shipped script already declares — the fixture changes
# the WORLD, never the clause.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
# classify_touches() reads CODEOWNERS at runtime; governance_paths() reads GOVERNANCE_LINT.
# The env overrides point both at non-existent paths to exercise the two probe-fail branches.
GUARDED_REPO="${GUARDED_REPO:-homelab}"
orphans=""