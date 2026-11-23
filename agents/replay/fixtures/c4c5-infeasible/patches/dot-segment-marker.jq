# dot-segment-marker: the same fail-open shape mid-path — `scripts/./node-maintenance.sh` is the
# codeowner-author scripts/node-maintenance.sh; canonicalized (`/./` collapsed) it parks.
map(if ((.body // "") | startswith("AGENT_INFEASIBLE:"))
    then .body = "AGENT_INFEASIBLE: scripts/./node-maintenance.sh — the fix edits the node-maintenance window script, a NEVER-TOUCH path for a worker. Ending without pushing."
    else . end)
