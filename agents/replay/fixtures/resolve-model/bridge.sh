# ── bridge ── common state for every resolve-model leg; each row's varying state
# (ROLE, FALLBACK, STUB_CURL, AGENT_EGRESS_PROXY, OVERRIDE, CURL_RESPONSE) is sourced from
# $REPLAY_WORLD/vars.sh — the row's `rows/<id>/vars.sh` overlay.
HERE="$REPLAY_ROOT/agents"
. "$REPLAY_WORLD/vars.sh"

# The resolve-model block reads ROUTER_URL from AGENT_EGRESS_PROXY or
# AGENT_OPENROUTER_PROXY.  Set a localhost stub address so curl always tries
# a non-existent port that the stub intercepts.
AGENT_EGRESS_PROXY="${AGENT_EGRESS_PROXY:-http://stub-router.agent-egress.svc:9999}"

# ── curl stub ──────────────────────────────────────────────────────────────────────────
# Shadow real curl with a function that:
#   - RECORDS the full invocation to the action stream
#   - SERVES CURL_RESPONSE when set (proxy-reachable arm)
#   - FAILS with exit 7 when STUB_CURL=fail (proxy-unreachable arm)
# The function is defined inside the composed script, so it overrides any PATH curl.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "${STUB_CURL:-ok}" in
    fail)
      printf 'curl: (7) Failed to connect\n' >&2
      return 7
      ;;
  esac
  if [ -n "${CURL_RESPONSE:-}" ]; then
    printf '%s' "$CURL_RESPONSE"
    return 0
  fi
  # No response configured — connection refused (shouldn't happen with valid vars)
  return 7
}

# Export so the block and stubs see them.
export ROLE FALLBACK CLASS CELL OVERRIDE STUB_CURL CURL_RESPONSE AGENT_EGRESS_PROXY REPLAY_ACTIONS REPLAY_WORLD