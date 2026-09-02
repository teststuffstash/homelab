HERE="$REPLAY_ROOT/agents"
PROXY_URL="http://openrouter-proxy.agent-egress.svc.cluster.local:8080"
_keyref=""
POD="agent-1268-subscription"
PROJECT="homelab"
TASK="issue-1268"
MODEL="claude/opus"
STRUCK_MODEL="claude/opus"
ROUND="1"
AGENT_RAIL="claude"
ERR_CLASS=""
PR_URL=""
STATS='{"exit_status":"clean","error_class":"","cost_usd":0.03}'
RUNLOG="/dev/null"

# Stub curl to return JSON without Authorization header when _keyref is empty
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # Return minimal JSON response (no provider on subscription rail)
  printf '{}\n'
  return 0
}

export -f curl
