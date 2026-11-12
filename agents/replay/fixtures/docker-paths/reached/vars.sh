# The condition: the claim scopes docker to the gateway island and the issue's machine block
# declares a footprint inside it (source only — not one of the gate's own paths).
DOCKER_PATHS='gateway/**'
_ib_body='---
Touches: gateway/src/agent_gateway/headroom.py
---
Tune the headroom poll.'
