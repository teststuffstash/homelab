# ── bridge ── goose harness (non-opencode).
#
# CONDITION UNDER REPLAY: HARNESS=goose, EGRESS_PROFILE unset.
# The hostAliases block should leave HOST_ALIASES empty — goose has no SDK-init fetches.
HARNESS="goose"
EGRESS_PROFILE=""