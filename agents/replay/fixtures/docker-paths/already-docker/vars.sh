# The condition: the ride is already docker (--docker, or fixer.docker=true) — the path scope is
# never consulted, even though the footprint does not reach it.
DOCKER_PATHS='gateway/**'
DOCKER=1
_ib_body='---
Touches: argocd/resources/garage-alerts/prometheusrule.yaml
---'
