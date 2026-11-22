# ── observation point ── not pod code: what the composition's harness line
# (`env "${PROBE_PARENT_ENV[@]}" claude -p … --model "$PROBE_PARENT_MODEL"`) hands claude, read
# through the same `env` argv; the session token is shown only as its prefix.
echo "parent model: ${PROBE_PARENT_MODEL} · child: ${PROBE_CHILD_HARNESS}/${PROBE_CHILD_MODEL}"
env "${PROBE_PARENT_ENV[@]}" bash -c 'echo "claude sees: ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL} ANTHROPIC_AUTH_TOKEN=${ANTHROPIC_AUTH_TOKEN:0:4}… ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-unset}"'
echo "env file left behind: $([ -n "${_gwp_env:-}" ] && [ -e "$_gwp_env" ] && echo yes || echo no)"
