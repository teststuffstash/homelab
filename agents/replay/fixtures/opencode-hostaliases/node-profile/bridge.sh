# ── bridge ── opencode harness, node egress profile, enforced.
#
# CONDITION UNDER REPLAY: HARNESS=opencode, EGRESS_ENFORCE=true, EGRESS_PROFILE=node.
# The hostAliases block should stub models.dev + models.opencode.ai but NOT registry.npmjs.org
# (which is legitimate node ecosystem traffic).
HARNESS="opencode"
EGRESS_ENFORCE="true"
EGRESS_PROFILE="node"