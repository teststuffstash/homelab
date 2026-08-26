# ── bridge ── opencode harness, node egress profile.
#
# CONDITION UNDER REPLAY: HARNESS=opencode, EGRESS_PROFILE=node.
# The hostAliases block should stub models.dev + models.opencode.ai but NOT registry.npmjs.org
# (which is legitimate node ecosystem traffic).
HARNESS="opencode"
EGRESS_PROFILE="node"