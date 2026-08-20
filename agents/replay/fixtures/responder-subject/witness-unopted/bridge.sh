# ── bridge ── the per-alert loop variables the gate reads.
#
# RouterRotationStale with project="homelab" but not opted in to project fallback.
# The subject computation should reach catch-all, yielding alert:RouterRotationStale.
# This prevents future misreadings of the opt-in pattern.
NAME="RouterRotationStale"
FP="d4e6f7g8h9i0j1k2"
_ns=""
a='{"status":"firing","fingerprint":"d4e6f7g8h9i0j1k2","labels":{"alertname":"RouterRotationStale","project":"homelab","severity":"warning"}}'
