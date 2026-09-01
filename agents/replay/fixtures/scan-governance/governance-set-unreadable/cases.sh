# ── the queued unit ── probes the governance-hold probe-fail branch when GOVERNANCE_LINT is unreadable.
# The one case tests that when GOVERNANCE_LINT points to a non-existent file, GOVERNANCE_PATHS becomes
# empty, triggering the probe-fail hold with the loud message rather than attempting to dispatch blind.
CASES="homelab|1009|policy/|update the access policy"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue
