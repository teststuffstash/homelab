# ── observation point ── what the manifest's code after the block reads: SP_MODEL empty = the latch
# path runs; the env the claude call gets; whether the env file survived. Then the EXIT trap's release.
echo "SP_STACK='${SP_STACK}' SP_MODEL='${SP_MODEL}' rail='${rail:-}' _gw=${_gw}"
echo "GW_LLM_ENV keys: $(printf '%s\n' "${GW_LLM_ENV[@]}" | cut -d= -f1 | paste -sd, -) · env file left: $([ -e /tmp/gw-llm.env ] && echo yes || echo no)"
echo "path after the block: $([ -n "$SP_MODEL" ] && echo gateway || echo old-proxy-latch)"
gw_release
