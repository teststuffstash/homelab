# The condition: same claim, but the declared footprint stays OUTSIDE both roots — a path that
# merely shares the `gateway/` parent is not a reach (prefix arithmetic stops at the `/` boundary):
# no pin read (an unrecorded `gh` read would die here), no fragment, no switch, no card line.
SPECS_CLAIM_JSON='{"root":"gateway/specs","tests":"gateway/tests"}'
_ib_body='---
Touches: agents/agent-session.sh, gateway/gateway.py, docs/agents/agentstack.md
---
Launcher clause.'
