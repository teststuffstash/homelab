# ── bridge ── the launcher state the block reads: a platform review (repo homelab, PR 42, round 1)
# dispatched by the review-platform cron (--loop-ns platform-agents → SA agentstack-loop), the pod
# name the currency gate computed, today's argv defaults. HERE = a temp dir with the REAL shared
# helper linked in and a fixture claims mirror. Each row overrides from $REPLAY_WORLD/vars.sh.
HERE="$(mktemp -d)"; ln -s "$REPLAY_ROOT/agents/gateway-admit.sh" "$HERE/gateway-admit.sh"
printf '%s' '{"stacks":[{"name":"platform","repos":["homelab",{"name":"agent-runtime"}]},{"name":"circles","repos":["circles"]}]}' > "$HERE/stacks.json"
PROJECT="homelab"; PR="42"; ROUND="1"; MODEL="sonnet"; MODEL_RAIL=""; GO_SERVED=0
NS="platform-agents"; POD_SA="agentstack-loop"; POD="reviewer-homelab-42-0a1b2c3d"
DECORRELATE_FROM="opencode-go/mimo-v2.6-pro"
GW_REPLY_HTTP="200"; GW_REPLY_BODY=""
_gw_tokf="$(mktemp)"; printf 'fake-caller-token-projected' > "$_gw_tokf"
AGENT_GATEWAY_CALLER_TOKEN_FILE="${AGENT_GATEWAY_CALLER_TOKEN_FILE-$_gw_tokf}"
. "$REPLAY_WORLD/vars.sh"
curl() {
  local _o="" _d="" _m="POST" _u="" _prev="" _auth=""
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
