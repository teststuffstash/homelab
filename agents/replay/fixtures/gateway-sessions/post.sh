# ── observation point ── not launcher code: what the rest of the launcher consumes. Reached only
# by rows the block lets through (off / other-stack / dispatch); the EXIT trap then releases.
echo "GW_SESSIONS='${GW_SESSIONS}' HARNESS='${HARNESS}' MODEL='${MODEL}'"
echo "GW_RAIL='${GW_RAIL}' GW_CONTEXT_TOKENS='${GW_CONTEXT_TOKENS}' GW_CLAUDE_MODEL='${GW_CLAUDE_MODEL}' OPENCODE_MODEL='${OPENCODE_MODEL:-}'"
echo "AGENT_ROUTER='${AGENT_ROUTER:-}' OR_CREDITS='${OR_CREDITS-unset}' STRUCK_MODEL='${STRUCK_MODEL:-}'"
_pe="${GW_ENV_JSON:-}"; [ -n "$_pe" ] || _pe='{}'
echo "GW_ENV keys: $(printf '%s' "$_pe" | jq -r 'keys | join(",")')"
