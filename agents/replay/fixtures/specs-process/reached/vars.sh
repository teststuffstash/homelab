# The condition: the claim names the roots, the issue's machine block (ADR-122, at the top of the
# body) declares a footprint INSIDE both of them — a spec page and a rule test — and the pin file at
# the base ref names v0.6.5, a release the registry serves as an image.
SPECS_CLAIM_JSON='{"root":"gateway/specs","tests":"gateway/tests"}'
_ib_body='---
Touches: gateway/specs/endpoints/sessions.md, gateway/tests/test_sessions.py
---
Tighten GW-SESSIONS-ENV.'
