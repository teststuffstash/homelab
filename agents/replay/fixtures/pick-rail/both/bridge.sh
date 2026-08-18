#!/usr/bin/env bash
# Bridge for pick-rail-both: _anthropic_clear returns 1, curl serves Go-limited.

# Set positional params for pick-rail mode
set -- --pick-rail

export PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
export TIER="${SUBSCRIPTION_TIER:-}"

# _anthropic_clear stub - returns 1 (latched)
if [ "${STUB_ANTHROPIC_CLEAR:-0}" = "1" ]; then
  _anthropic_clear() { return 1; }
else
  _anthropic_clear() { return 0; }
fi

# curl stub: records calls, serves Go-limited JSON
curl() {
  local url=""
  for a in "$@"; do
    case "$a" in
      -fsS|-sS|-fs|--max-time) ;;
      [0-9]) ;;
      http://*|https://*/) url="$a" ;;
    esac
  done
  printf 'CALL curl %s\n' "$url" >> "$REPLAY_ACTIONS"
  case "$url" in
    */opencode-limit)
      if [ -f "$REPLAY_WORLD/curl/opencode-limit.json" ]; then
        cat "$REPLAY_WORLD/curl/opencode-limit.json"
        return 0
      fi
      printf '{"limited": true}'
      return 0
      ;;
  esac
  return 0
}
