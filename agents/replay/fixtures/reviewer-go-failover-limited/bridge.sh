# ── bridge — seams only, no gate logic. Sets HERE to fixture dir for subscription-latch.sh stub,
# provides curl function that records calls and serves world JSON for /opencode-limit.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
MODEL="sonnet"
GO_SERVED=0
# MODEL_SET_EXPLICIT is NOT set — the gate's failover condition is tested, but Go is limited so it defers

# subscription-latch.sh: print the latch message to stderr and exit 1 (Anthropic is latched)
subscription-latch.sh() {
  echo "subscription limited (FU-088, 429): utilization high — deferring subscription dispatch" >&2
  return 1
}

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
      printf '{"limited": true, "reason": "429"}'
      return 0
      ;;
  esac
  echo "curl: unexpected URL: $url" >&2
  return 1
}
