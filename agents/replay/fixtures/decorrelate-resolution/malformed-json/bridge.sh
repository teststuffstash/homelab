# ── bridge ── launcher state for the decorrelate-resolution malformed-json leg.
# The proxy returns a non-JSON response (simulating an upstream error). jq fails on
# parse error, _last_model is empty, "not available" logged. No crash.
pick_issue="123"
PROXY_URL="http://proxy.test:8080"
repo="test-project"

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf 'not valid json at all'
}

log() {
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$REPLAY_ACTIONS"
}
export -f log 2>/dev/null || true