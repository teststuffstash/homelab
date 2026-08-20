# ── bridge ── AgentRunPhaseSlow with project label but NOT opted in.
#
# Simulates a phase-slow alert from openrouter-operator project.
# The alert is NOT in the case list for project fallback (fleet-level decision),
# so subject computation should reach catch-all, yielding alert:AgentRunPhaseSlow.
#
NAME="AgentRunPhaseSlow"
FP="p9o8i7u6y5t4r3e2"
_ns=""
a='{"status":"firing","fingerprint":"p9o8i7u6y5t4r3e2","labels":{"alertname":"AgentRunPhaseSlow","project":"openrouter-operator","phase":"devbox-install","severity":"warning"}}'