# The template's PAYLOAD is the Alertmanager delivery; run_one_alert is the seam (the template re-runs
# its own script, `bash -lc "$BASH_EXECUTION_STRING"`, with the one-alert payload) — stubbed to record
# each child's payload and fail for FAIL_REPO, so a red child is visible in the parent's RC.
PAYLOAD="$(cat "$REPLAY_WORLD/alert.json")"
run_one_alert() {
  echo "PASS $(jq -c '[(.alerts | length), (.alerts[0] | .status, .labels.repo, .labels.branch, .labels.id)]' <<< "$1")"
  [ "$(jq -r '.alerts[0].labels.repo' <<< "$1")" != "${FAIL_REPO:-}" ]
}
