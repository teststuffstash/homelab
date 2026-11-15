# The condition: same claim, the footprint touches the island but not its specs root (the README one
# level up) — nothing engages: no README read (an unrecorded `gh` read would die), no card line.
SPECS_CLAIM_JSON='{"root":"gateway/specs","tests":"gateway/tests"}'
EXTRA_SPECS_CLAIM_JSON='[{"root":"islands/scan/specs"},{"root":"islands/launch/specs"},{"root":"islands/retro/specs"}]'
_ib_body='---
Touches: islands/launch/README.md, islands/launch/specs-notes.md
---'
