# ── bridge ── launcher state for the resolved-absent leg.
# _decision has no .resolved field (legacy response). The carrier parse inside the
# route-request block skipped cleanly. MODEL_RAIL is never set, GO_SERVED=0.
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
CURL_DECISION='{"decision":"dispatch","model":"sonnet","reason":"class","basis":"capacity"}'

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '%s' "$CURL_DECISION"
}

python3() {
  printf 'CALL python3 %s\n' "$*" >> "$REPLAY_ACTIONS"
  command python3 "$@"
}