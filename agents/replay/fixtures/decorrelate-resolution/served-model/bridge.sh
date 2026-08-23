# ── bridge ── launcher state for the decorrelate-resolution served-model leg.
# The proxy returns a valid report with served_model, so decorrelate_arg is produced.
pick_issue="123"
PROXY_URL="http://proxy.test:8080"
repo="test-project"

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '{"served_model":"gpt-4o","model":"openrouter/gpt-4o"}'
}

log() {
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$REPLAY_ACTIONS"
}
export -f log 2>/dev/null || true