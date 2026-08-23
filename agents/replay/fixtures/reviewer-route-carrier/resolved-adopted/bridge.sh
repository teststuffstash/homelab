# ── bridge ── launcher state for the resolved-adopted leg.
# _decision holds .resolved={rail:"opencode-go",harness:"go",model:"opencode-go/gpt-4o"}
# and the router's decision was adopted (_router_adopted=1).
# GO_SERVED=1 because rail=opencode-go. model_id.py is called (MODEL_MODEL is non-empty)
# and re-derives the carrier values (overriding MODEL_HARNESS from 'go' to 'claude').
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
CURL_DECISION='{"decision":"dispatch","model":"opencode-go/gpt-4o","reason":"class","basis":"capacity","resolved":{"rail":"opencode-go","harness":"go","model":"opencode-go/gpt-4o"}}'

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '%s' "$CURL_DECISION"
}

python3() {
  printf 'CALL python3 %s\n' "$*" >> "$REPLAY_ACTIONS"
  command python3 "$@"
}