# A grouped MgmtApplyErroredOnNewProvider delivery: two firing alerts of the group + one other alertname (not admitted). The
# seam run_one_alert (the template re-runs its own script with a one-alert payload) is stubbed to
# record each child's payload.
PAYLOAD='{"alerts":[{"status":"firing","labels":{"alertname":"MgmtApplyErroredOnNewProvider","root":"main","provider":"kubernetes","locked":"3.2.1"}},{"status":"firing","labels":{"alertname":"Watchdog"}},{"status":"firing","labels":{"alertname":"MgmtApplyErroredOnNewProvider","root":"main","provider":"helm","locked":"3.1.0"}}]}'
run_one_alert() { echo "PASS $(jq -c '[(.alerts | length), .alerts[0].labels.provider]' <<< "$1")"; }
