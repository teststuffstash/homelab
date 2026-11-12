# The condition: the claim scopes docker to the gateway island; the issue declares a footprint
# elsewhere in the repo — a plain pod whose card names the paths it must not wander into.
DOCKER_PATHS='gateway/**'
_ib_body='---
Touches: argocd/resources/garage-alerts/prometheusrule.yaml
---
Raise the threshold.'
