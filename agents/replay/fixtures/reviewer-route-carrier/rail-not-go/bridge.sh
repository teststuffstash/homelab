# ── bridge ── launcher state for the rail-not-go leg.
# _decision holds .resolved with rail="anthropic-subscription" (not "opencode-go").
# GO_SERVED stays 0. model_id.py is called.
AGENT_ROUTER="authoritative"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
ROUTER_URL="http://proxy.test:8080"
HERE="$REPLAY_ROOT/agents"
PROJECT="test-project"
PR="42"
ROUND="1"
DECORRELATE_FROM=""
_srow='{"name":"test","modelDeny":[]}'
MODEL="sonnet"
CURL_DECISION='{"decision":"dispatch","model":"claude/sonnet","reason":"class","basis":"capacity","resolved":{"rail":"anthropic-subscription","harness":"claude","model":"sonnet"}}'

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '%s' "$CURL_DECISION"
}

python3() {
  printf 'CALL python3 %s\n' "$*" >> "$REPLAY_ACTIONS"
  command python3 "$@"
}