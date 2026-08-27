# ── bridge ── opencode harness, default (non-node) egress profile, enforced.
#
# CONDITION UNDER REPLAY: HARNESS=opencode, EGRESS_ENFORCE=true, EGRESS_PROFILE unset.
# The hostAliases block should produce stubs for all three destinations.
HARNESS="opencode"
EGRESS_ENFORCE="true"
EGRESS_PROFILE=""