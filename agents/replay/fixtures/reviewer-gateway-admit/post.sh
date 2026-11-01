# ── observation point ── not launcher code: what the rest of the launcher (the go-failover gate,
# the rail label, the pod manifest, ARGS) consumes. Reached by every row the block lets through;
# the EXIT trap then releases a dispatched session.
echo "GW_SESSIONS='${GW_SESSIONS}' MODEL='${MODEL}' MODEL_RAIL='${MODEL_RAIL}' GO_SERVED=${GO_SERVED}"
echo "AGENT_ROUTER='${AGENT_ROUTER:-}' _router_adopted='${_router_adopted:-}' GW_PULL_PRELUDE set: $([ -n "${GW_PULL_PRELUDE}" ] && echo yes || echo no)"
echo "LABEL:${REVIEW_GW_LABEL}"
printf 'POD LLM ENV:\n%s\n' "$REVIEW_LLM_ENV"
echo "MOUNT:$([ -n "$GW_TOKEN_MOUNT" ] && echo gateway-token || echo none) VOLUME:$([ -n "$GW_TOKEN_VOLUME" ] && echo gateway-token || echo none)"
