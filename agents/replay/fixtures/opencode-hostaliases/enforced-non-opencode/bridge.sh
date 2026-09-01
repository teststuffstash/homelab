# ── bridge ── goose harness (non-opencode), enforced egress, default (non-node) profile.
#
# CONDITION UNDER REPLAY: HARNESS=goose, EGRESS_ENFORCE=true, EGRESS_PROFILE unset.
# The opencode block produces nothing (HARNESS != opencode), but the registry.npmjs.org block
# fires because EGRESS_ENFORCE=true and EGRESS_PROFILE != node.
HARNESS="goose"
EGRESS_ENFORCE="true"
EGRESS_PROFILE=""