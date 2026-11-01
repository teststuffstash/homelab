# ── bridge ── what the decide step holds when it reaches the set-pass block: the helper sourced from
# the checkout (the manifest sources /work/homelab's copy above its first block), the two /tmp files
# the claims read + pending set wrote, the pod's projected caller token (a temp file), and `curl` as
# the gateway: it records every call and serves the row's answer ($GW_REPLY_HTTP + $GW_REPLY_BODY;
# 000 = connection refused). AGENT_GATEWAY comes from the row's env cell, like the pod's env.
set -u
_gw_tokf="$(mktemp)"; printf 'fake-caller-token-projected' > "$_gw_tokf"
AGENT_GATEWAY_CALLER_TOKEN_FILE="$_gw_tokf"
GW_REPLY_HTTP="200"; GW_REPLY_BODY='""'
SET_REPOS="teststuffstash/homelab teststuffstash/agent-runtime"
. "$REPLAY_WORLD/vars.sh"   # may override any of the four above (no-token-fallback: the token file)
. "$REPLAY_ROOT/agents/gateway-admit.sh"
printf 'agent-runtime\tplatform\t\nhomelab\tplatform\t\noracle-fleet\toracle\toracle-agents\n' > /tmp/stackmap.tsv
: > /tmp/set.jsonl; _n=10; for _r in $SET_REPOS; do _n=$((_n+1)); printf '{"repo":"%s","number":%s,"title":"t"}\n' "$_r" "$_n" >> /tmp/set.jsonl; done
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
