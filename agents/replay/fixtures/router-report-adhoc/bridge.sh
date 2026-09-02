HERE="$REPLAY_ROOT/agents"
PROXY_URL="http://openrouter-proxy.agent-egress.svc.cluster.local:8080"
_keyref=""
POD="agent-adhoc-r1"
PROJECT="homelab"
TASK="adhoc-migrate-cert"
MODEL="claude/opus"
STRUCK_MODEL="claude/opus"
ROUND="1"
AGENT_RAIL="subscription"
ERR_CLASS=""
PR_URL=""
STATS='{"exit_status":"clean","error_class":"","cost_usd":0.02}'
RUNLOG="/dev/null"

# Stub curl to return JSON with provider (but no Authorization header on subscription rail)
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # No Authorization header expected for subscription rides
  printf '{"provider":""}\n'
  return 0
}

export -f curl
