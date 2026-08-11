# ── bridge ── two seams, both underneath the block: the wall clock and the transport.
#
# `curl` is shadowed rather than PATH-shimmed for the reason agents/replay/README.md gives for the
# responder pair — a third stub buys nothing. The PAYLOAD is recorded too (it arrives on stdin via
# `--data-binary @-`), because the metric names and the `in_deterministic` value ARE the contract
# the alert reads; a fixture that pinned only the URL would go green on an inverted gauge.
sp_now() { printf '1786464900'; }

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

echo "REACHED: dispatch transition"
scan_phase dispatch
printf 'RETURN %s\n' "$?"

echo "REACHED: back in the deterministic pass"
scan_phase deterministic
printf 'RETURN %s\n' "$?"

# An unknown phase is a caller bug, not a scan failure: say so, push nothing, return 0.
echo "REACHED: unknown phase"
scan_phase sideways
printf 'RETURN %s\n' "$?"

# A run with no gateway (the jail/manual path, AGENT_PUSHGATEWAY_URL=""): no marker at all, which
# is exactly the state the alert's no-marker branch is written for.
echo "REACHED: gateway disabled"
SCAN_PHASE_PGW="" scan_phase dispatch
printf 'RETURN %s\n' "$?"

# The gateway is up but refuses (curl exit 7): one warning, and the dispatch is unaffected.
echo "REACHED: gateway refuses the push"
CURL_RC=7 scan_phase dispatch
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
