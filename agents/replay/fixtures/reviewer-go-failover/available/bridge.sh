# ── bridge — seams only, no gate logic. Sets HERE to fixture dir for subscription-latch.sh stub,
# provides curl function that records calls and serves world JSON for /opencode-limit.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL="sonnet"
GO_SERVED=0
# MODEL_SET_EXPLICIT is NOT set — the gate's failover condition is true when Go is available

# The latch seam is the stub FILE $HERE/subscription-latch.sh — the real gate runs
# `bash "$HERE/subscription-latch.sh"`, which a shell function could not intercept.

# curl stub: records the call and serves world JSON for /opencode-limit
curl() {
  local url=""
  for a in "$@"; do
    case "$a" in
      -fsS|-sS|-fs|--max-time) ;;
      [0-9]) ;;  # skip numeric timeout value
      http://*|https://*/) url="$a" ;;
    esac
  done
  # Record the call
  printf 'CALL curl %s\n' "$url" >> "$REPLAY_ACTIONS"
  # Serve from world if available
  case "$url" in
    */opencode-limit)
      if [ -f "$REPLAY_WORLD/curl/opencode-limit.json" ]; then
        cat "$REPLAY_WORLD/curl/opencode-limit.json"
        return 0
      fi
      # Fallback inline
      printf '{"limited": false, "semaphore": {"running": 1, "max": 10}}'
      return 0
      ;;
  esac
  echo "curl: unexpected URL: $url" >&2
  return 1
}
