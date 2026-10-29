# The condition: reached, the pin reads (v0.6.4), but the registry serves no manifest for that tag
# (the release predates the process image) — the LOUD degrade's second arm: no probe, no fragment,
# the card says so. A wildcard footprint reaches everything, exactly as it does for the scan's hold.
SPECS_CLAIM_JSON='{"root":"gateway/specs","tests":"gateway/tests"}'
_ib_body='---
Touches: *
---'
