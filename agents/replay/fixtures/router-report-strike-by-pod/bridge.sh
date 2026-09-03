HERE="$REPLAY_ROOT/agents"
PROXY_URL="http://openrouter-proxy.agent-egress.svc.cluster.local:8080"
_keyref="homelab/homelab-session-1268-pod-struck"
POD="agent-1268-pod-struck"
PROJECT="homelab"
TASK="issue-1268"
MODEL="deepseek/deepseek-v4-flash"
STRUCK_MODEL="deepseek/deepseek-v4-flash"
ROUND="3"
AGENT_RAIL="openrouter"
STRIKE_BY_POD="true"
ERR_CLASS=""
PR_URL=""
STATS='{"exit_status":"clean","error_class":"","cost_usd":0.03}'
RUNLOG="/dev/null"

# Stub curl to return JSON with provider when Authorization header is present
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # Return JSON response with provider field
  printf '{"provider":"openrouter"}\n'
  return 0
}

export -f curl
