# ── bridge ── the probe pod's state when the block starts: the env the composition renders for a
# claim with prober.gateway (PROBE_MODEL, the ref rail's ANTHROPIC_* pair, PROBE_STACK), a claude
# child as the child block leaves it, the projected caller token (a temp file holding a fixture
# string). `hostname` is the Argo pod name. `curl` serves the row's gateway answer exactly as in
# gateway-admit (HTTP 000 = connection refused, curl exit 7) and records every call. vars.sh may
# override any of it (the knob, the reply, a codex child with its own `_gw_release`).
_gw_tokf="$(mktemp)"; printf 'fake-caller-token-projected' > "$_gw_tokf"
export AGENT_GATEWAY_CALLER_TOKEN_FILE="$_gw_tokf"
export AGENT_GATEWAY_URL="http://agent-gateway.agent-egress.svc.cluster.local:8080"
export PROBE_MODEL=haiku PROBE_STACK=platform PROBE_GATEWAY=sessions
export ANTHROPIC_BASE_URL="http://openrouter-proxy.agent-egress.svc.cluster.local:8080/anthropic"
export ANTHROPIC_AUTH_TOKEN="ref:platform-agents/claude-session"
export PROBE_CHILD_HARNESS=claude PROBE_CHILD_MODEL="$PROBE_MODEL"
hostname() { printf 'probe-platform-1730000000\n'; }
GW_REPLY_HTTP="200"; GW_REPLY_BODY='""'
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
. "$REPLAY_WORLD/vars.sh"
