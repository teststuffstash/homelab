# ── bridge ── three seams the block calls at RUN time (definition order vs the block does not
# matter for bash function resolution; fanout_clear is block-defined and overridden in drive.sh).
#
# curl: recorded, WITHOUT reading stdin — the ring passes its payload via -d, so a seam that
# drained stdin (the dispatch-phase pattern, where the push pipes its body) would hang or eat
# the driver. The -d payload lands in the CALL line, which is exactly the assertion.
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  return "${CURL_RC:-0}"
}

# The stack universe: two graduated stacks + repos. Only .name/.repos/index are read here.
stacks_json() {
  cat <<'JSON'
{ "stacks": [
  { "name": "circles", "graduated": true, "repos": ["circles-iac", "circles"] },
  { "name": "sleep",   "graduated": true, "repos": ["sleep-iac", "sleep-tracking", "snore-recorder"] }
] }
JSON
}

# Every leg pins DISPATCH_PHASE_WAKE itself (the wake probe is dispatch-phase-scan's pin, not
# this family's) — a leg that forgot would fall through here and die loudly.
dp_wake() { printf '%s' "${DP_WAKE:?this leg must pin DISPATCH_PHASE_WAKE (dp_wake is not under test here)}"; }
