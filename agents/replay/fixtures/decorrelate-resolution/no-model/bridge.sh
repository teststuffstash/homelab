# ── bridge ── launcher state for the decorrelate-resolution no-model leg.
# The proxy returns valid JSON but missing both served_model and model.
# jq -r '.served_model // .model // ""' returns "", "not available" logged.
pick_issue="123"
PROXY_URL="http://proxy.test:8080"
repo="test-project"

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '{"status":"ok"}'
}

log() {
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$REPLAY_ACTIONS"
}
export -f log 2>/dev/null || true