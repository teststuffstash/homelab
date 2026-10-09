# ── observation point ── the two call sites (as in `uploads`), then the typed field itself: the
# action stream alone shows only that finding.json went up, never what it says.
_ts_session
_ts_finding "report-only" "" "teststuffstash/homelab"
echo "would: $(jq -c '{schema, remediation_would}' /tmp/ts-finding.json)"
echo "REACHED: end"
