"""agent-gateway — the LLM egress gateway for the agent fleet (homelab gateway/, ADR-139 P2).

The contract lives in `gateway/specs/` (requirement ids `GW-…`); this package is the v0 service
half. No model id lives in code — policy.json carries them (GW-MODEL-RESOLVE).
"""

__version__ = "0.1.0"
