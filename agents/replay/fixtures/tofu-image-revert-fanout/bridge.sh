# A grouped KubeDeploymentRolloutStuck delivery: two firing alerts of the group + one other alertname (not admitted). The
# seam run_one_alert (the template re-runs its own script with a one-alert payload) is stubbed to
# record each child's payload.
PAYLOAD='{"alerts":[{"status":"firing","labels":{"alertname":"KubeDeploymentRolloutStuck","namespace":"home-assistant","deployment":"homeassistant"}},{"status":"firing","labels":{"alertname":"Watchdog"}},{"status":"firing","labels":{"alertname":"KubeDeploymentRolloutStuck","namespace":"unifi","deployment":"unifi"}}]}'
run_one_alert() { echo "PASS $(jq -c '[(.alerts | length), .alerts[0].labels.deployment]' <<< "$1")"; }
