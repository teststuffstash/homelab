# ── doorbell-fanout-wiring bridge ──
# Stubs for the REPLAY:doorbell-fanout and REPLAY:doorbell-fanout-callsite blocks.
# Based on agents/replay/fixtures/doorbell/fanout/bridge.sh.

# Set HERE so the block's fanout_clear (which calls HERE/subscription-latch.sh) works.
HERE="${REPLAY_ROOT}/agents"

# curl: recorded, WITHOUT reading stdin — the ring passes its payload via -d.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  return "${CURL_RC:-0}"
}

# The stack universe: two graduated stacks + repos.
stacks_json() {
  cat <<'JSON'
{ "stacks": [
  { "name": "circles", "graduated": true, "repos": ["circles-iac", "circles"] },
  { "name": "sleep",   "graduated": true, "repos": ["sleep-iac", "sleep-tracking", "snore-recorder"] }
] }
JSON
}

# dp_wake — each row pins its own DISPATCH_PHASE_WAKE via DP_WAKE.
dp_wake() { printf '%s' "${DP_WAKE:?this leg must pin DISPATCH_PHASE_WAKE}"; }

# No fanout_clear here — the block defines it. Override comes after the block
# in latch-override.sh so the override wins (see fixture.yaml parts order).