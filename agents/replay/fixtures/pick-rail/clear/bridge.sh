#!/usr/bin/env bash
# Bridge for pick-rail-clear: stub _anthropic_clear and curl, set up env.

# Set positional params so the pick-rail block runs
set -- --pick-rail

# Set up the env vars the pick-rail block expects
export PROXY="${AGENT_EGRESS_PROXY:-http://openrouter-proxy.agent-egress.svc.cluster.local:8080}"
export TIER="${SUBSCRIPTION_TIER:-}"

# _anthropic_clear stub via env flag - returns 0 (clear) for this fixture
if [ "${STUB_ANTHROPIC_CLEAR:-0}" = "1" ]; then
  _anthropic_clear() { return 0; }
else
  _anthropic_clear() { return 1; }
fi

# curl stub: records calls to REPLAY_ACTIONS, serves world JSON for Go probe
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
      printf '{"limited": false}'
      return 0
      ;;
  esac
  return 0
}
