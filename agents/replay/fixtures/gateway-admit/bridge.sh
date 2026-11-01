# ── bridge ── the helper sourced as a launcher sources it, under set -u; the caller token is the
# projected-file default (a temp file holding a plain fixture string). `curl` serves the row's
# gateway answer ($GW_REPLY_HTTP + $GW_REPLY_BODY; HTTP 000 = connection refused, curl exit 7) and
# records every call; an unbound answer's session token is `gws_` + 32 A's — post.sh greps every
# shell variable for it.
set -u
_gw_tokf="$(mktemp)"; printf 'fake-caller-token-projected' > "$_gw_tokf"
AGENT_GATEWAY_CALLER_TOKEN_FILE="$_gw_tokf"
. "$REPLAY_ROOT/agents/gateway-admit.sh"
GW_REPLY_HTTP="200"; GW_REPLY_BODY='""'; ENVF="$REPLAY_WORLD/llm.env"; ADMIT_ARGS=()
. "$REPLAY_WORLD/vars.sh"
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
gw_preflight_caller
rc=0; gw_admit "${ADMIT_ARGS[@]}" || rc=$?
