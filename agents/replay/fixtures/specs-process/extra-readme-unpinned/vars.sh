# The condition: same claim and reach, but the launch root's README links no versioned RULES.md —
# the fallback: the repo's PRIMARY pin file (the gateway's layout default), said on stderr, mounted.
SPECS_CLAIM_JSON='{"root":"gateway/specs","tests":"gateway/tests"}'
EXTRA_SPECS_CLAIM_JSON='[{"root":"islands/scan/specs"},{"root":"islands/launch/specs"},{"root":"islands/retro/specs"}]'
_ib_body='---
Touches: islands/launch/specs/x.md
---'
