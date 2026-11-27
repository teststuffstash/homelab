# The condition: homelab's claim (the gateway pair + three island roots under `extraSpecs`), the
# footprint reaches ONLY islands/launch/specs — the primary pair stays silent, the launch root's
# README (recorded from master: its §Rules links `RULES.md @ v0.6.9`) names the version, mounted.
SPECS_CLAIM_JSON='{"root":"gateway/specs","tests":"gateway/tests"}'
EXTRA_SPECS_CLAIM_JSON='[{"root":"islands/scan/specs"},{"root":"islands/launch/specs"},{"root":"islands/retro/specs"}]'
_ib_body='---
Touches: islands/launch/specs/x.md
---'
