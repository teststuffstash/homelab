HERE="$REPLAY_ROOT"
PROXY_URL="http://openrouter-proxy.agent-egress.svc.cluster.local:8080"
_keyref="homelab/homelab-session-1268"
POD="agent-1268-r2"
PROJECT="homelab"
TASK="issue-1268"
MODEL="deepseek/deepseek-v4-flash"
ROUND="2"
AGENT_RAIL="openrouter"
ERR_CLASS=""
PR_URL=""
STATS='{"exit_status":"clean","error_class":"","cost_usd":0.05}'

# Stub curl to return JSON with provider when Authorization header is present
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # Return JSON response with provider field
  printf '{"provider":"openrouter"}\n'
  return 0
}

export -f curl
