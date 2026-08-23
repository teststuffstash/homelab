# ── bridge ── launcher state for the decorrelate-resolution empty-report leg.
# The proxy returns an empty string (simulating a missing/no-data report).
# _last_report is empty after the curl, the jq is never reached, "not available" logged.
pick_issue="123"
PROXY_URL="http://proxy.test:8080"
repo="test-project"

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf ''
}

log() {
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$REPLAY_ACTIONS"
}
export -f log 2>/dev/null || true