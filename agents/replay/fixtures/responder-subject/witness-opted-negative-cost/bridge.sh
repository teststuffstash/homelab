# ── bridge ── AgentRunNegativeCost with project label, opted in.
#
# Simulates a negative cost alert from openrouter-operator project.
# The opt-in should cause _ns to fall back to the project label,
# yielding subject ns:openrouter-operator instead of alert:AgentRunNegativeCost.
#
NAME="AgentRunNegativeCost"
FP="a1b2c3d4e5f6g7h8"
_ns=""
a='{"status":"firing","fingerprint":"a1b2c3d4e5f6g7h8","labels":{"alertname":"AgentRunNegativeCost","project":"openrouter-operator","issue":"123","model":"claude-3-sonnet","round":"1","severity":"warning"}}'
