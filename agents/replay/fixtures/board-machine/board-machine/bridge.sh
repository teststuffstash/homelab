# ── bridge ── shadows curl to return synthetic Prometheus agent_item_class data.
#
# The board.sh --machine mode queries Prometheus via:
#   curl -sS --max-time 10 "${PROMETHEUS_URL}/api/v1/query" --data-urlencode "query=$1"
# We intercept the call and return a recorded JSON response matching the Prometheus API format.
curl() {
  local args="$*"
  printf 'CALL curl %s\n' "$args" >> "$REPLAY_ACTIONS"
  # Check if this is a Prometheus query for agent_item_class
  if [[ "$args" == *"/api/v1/query"* ]]; then
    # Return synthetic data for the 5 fixture classes
    printf '{"status":"success","data":{"resultType":"vector","result":[
      {"metric":{"repo":"homelab","item":"833","class":"held-merged-unlinked","who":"operator"},"value":[1786465900,"1"]},
      {"metric":{"repo":"homelab","item":"834","class":"queued-held-by-ghost","who":"operator"},"value":[1786465900,"1"]},
      {"metric":{"repo":"homelab","item":"889","class":"riding","who":"machine"},"value":[1786465900,"1"]},
      {"metric":{"repo":"homelab","item":"840","class":"container","who":"none"},"value":[1786465900,"1"]},
      {"metric":{"repo":"homelab","item":"aggregate","class":"backlog-aggregate","who":"operator"},"value":[1786465900,"1"]}
    ]}}' >> "$REPLAY_ACTIONS"
  fi
  return 0
}

# board.sh sources the touches-check.sh and goal-findings.sh helpers, which are on disk.
# For the --machine mode, we only need to test the Prometheus query and rendering.
# We run the real board.sh with --machine flag.

# The stubs need to handle the gh and kubectl calls that board.sh makes to discover repos.
# Since the --machine mode reads from Prometheus, the gh/kubectl calls are only for the
# stack → repo resolution. We stub them to return minimal data.

# Run board.sh --machine with the platform stack (default)
bash "$REPLAY_ROOT/agents/board.sh" --machine platform
printf 'EXIT %s\n' "$?"