# ── observation point ── not launcher code: what the launcher rendered, then the in-pod function
# RUN against the seams (the pod's shell: bash, set +e, the manifest env exported).
echo "GW_COORD='${GW_COORD}'"
printf 'RUNNER %s\n' "$RUNNER"
if [ -z "$COORD_GW_FN" ]; then echo "COORD_GW_FN: empty"; echo "REACHED: end"; exit 0; fi
set +u +e
_t="$REPLAY_WORLD/pod"; mkdir -p "$_t/agents" "$_t/bin" "$_t/tmp"
ln -s "$REPLAY_ROOT/agents/gateway-admit.sh" "$_t/agents/gateway-admit.sh"
printf '#!/bin/sh\necho "CALL subscription-latch SUBSCRIPTION_TIER=$SUBSCRIPTION_TIER" >> %s\nexit %s\n' "$REPLAY_ACTIONS" "$LATCH_RC" > "$_t/agents/subscription-latch.sh"
printf '#!/bin/sh\necho "CALL claude $* [ANTHROPIC_BASE_URL=$ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN=$ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL=${ANTHROPIC_MODEL:-} CLAUDE_CODE_MAX_CONTEXT_TOKENS=${CLAUDE_CODE_MAX_CONTEXT_TOKENS:-}]" >> %s\nexit 0\n' "$REPLAY_ACTIONS" > "$_t/bin/claude"
chmod +x "$_t/bin/claude"
PATH="$_t/bin:$PATH"; COORD_HOMELAB="$_t"; TMPDIR="$_t/tmp"
AGENT_GATEWAY_CALLER_TOKEN_FILE="$_t/caller-token"
[ "$TOKEN_PRESENT" = 1 ] && printf 'fake-caller-token-projected' > "$AGENT_GATEWAY_CALLER_TOKEN_FILE"
export ANTHROPIC_BASE_URL="http://openrouter-proxy.agent-egress.svc.cluster.local:8080/anthropic"
export ANTHROPIC_AUTH_TOKEN="ref:agent-coordinator/coordinator-claude"
export MODEL
cat() { if [ "${1:-}" = "/work/coord-run" ]; then printf '%s' "$RUN_CMD"; else command cat "$@"; fi; }
curl() {
  local _o="" _d="" _m="POST" _u="" _prev="" _auth="" _a
  for _a in "$@"; do
    case "$_prev" in -o) _o="$_a";; -d) _d="$_a";; -X) _m="$_a";;
      -H) case "$_a" in @*) _auth="$(sed -n 's/^Authorization: //p' "${_a#@}")";; esac;; esac
    case "$_a" in http*) _u="$_a";; esac
    _prev="$_a"
  done
  printf 'CALL curl %s %s [auth: %s]%s\n' "$_m" "$_u" "${_auth:-none}" "${_d:+ $_d}" >> "$REPLAY_ACTIONS"
  [ "$_m" = "DELETE" ] && return 0
  if [ "$GW_REPLY_HTTP" = "000" ]; then printf '000'; return 7; fi
  [ -z "$_o" ] || printf '%s' "$GW_REPLY_BODY" > "$_o"
  printf '%s' "$GW_REPLY_HTTP"
}
eval "$COORD_GW_FN"
coord_gw_claude; rc=$?
echo "rc=${rc} CS_DEFERRED='${CS_DEFERRED:-}' MODEL='${MODEL}' env file left: $([ -e "$_t/tmp/coord-gw.env" ] && echo yes || echo no)"
echo "REACHED: end"
