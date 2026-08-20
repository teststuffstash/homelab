# ── bridge ── AgentRunInfraDeathBurst with project label, opted in.
#
# Simulates an infra death burst alert from sleep-tracking project.
# The opt-in should cause _ns to fall back to the project label,
# yielding subject ns:sleep-tracking instead of alert:AgentRunInfraDeathBurst.
#
NAME="AgentRunInfraDeathBurst"
FP="i8j7k6l5m4n3o2p1"
_ns=""
a='{"status":"firing","fingerprint":"i8j7k6l5m4n3o2p1","labels":{"alertname":"AgentRunInfraDeathBurst","project":"sleep-tracking","severity":"warning"}}'
