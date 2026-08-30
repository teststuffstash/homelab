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

# ── CLI subprocess test ──────────────────────────────────────────────────────────
# When CLI_FLAGS is non-empty, invoke resolve-model.sh as a real subprocess through
# the flag shape the launchers use (retro-session.sh:66, coordinator-session.sh:106/112),
# instead of the block-level env-var entry point.  This is the ADDITIVE row the issue
# #870 deliverable demands — the block-level rows are unchanged.
#
# The curl function above is a shell function inside the composed script; a subprocess
# does not inherit it.  Create a temporary curl stub on PATH that mirrors the same
# CALL-record + serve-or-fail contract.
if [ -n "${CLI_FLAGS:-}" ]; then
  _cli_stub="$(mktemp -d)"
  cat > "$_cli_stub/curl" << 'CURLSTUB'
#!/usr/bin/env bash
printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
case "${STUB_CURL:-ok}" in
  fail) echo "curl: (7) Failed to connect" >&2; exit 7 ;;
esac
if [ -n "${CURL_RESPONSE:-}" ]; then
  printf '%s' "$CURL_RESPONSE"
  exit 0
fi
exit 7
CURLSTUB
  chmod +x "$_cli_stub/curl"

  # Run resolve-model.sh as a subprocess with the stub on PATH.
  # The subprocess's stdout/stderr are captured by the fixture framework,
  # and the CALL curl lines are written to the actions file by the stub.
  PATH="$_cli_stub:$PATH" bash "$REPLAY_ROOT/agents/resolve-model.sh" $CLI_FLAGS
  rc=$?
  rm -rf "$_cli_stub"
  exit $rc
fi