# ── bridge ── opencode harness, monitor-mode (EGRESS_ENFORCE unset).
#
# CONDITION UNDER REPLAY: HARNESS=opencode, EGRESS_ENFORCE unset, EGRESS_PROFILE unset.
# The hostAliases block should leave HOST_ALIASES empty — the gate requires enforce=true.
HARNESS="opencode"
EGRESS_ENFORCE=""
EGRESS_PROFILE=""