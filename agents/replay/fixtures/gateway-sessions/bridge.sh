# ── bridge ── the launcher state the block reads, as a platform (homelab project) ad-hoc ride with
# today's argv defaults; each row overrides from $REPLAY_WORLD/vars.sh. `curl` serves the row's
# gateway answer ($GW_REPLY_HTTP + $GW_REPLY_BODY; HTTP 000 = connection refused, curl exit 7)
# and records every call. The fake token is `gws_` + 32 A's — post.sh greps for it.
PROJECT="homelab"; TASK=""; ROUND="1"; HARNESS="opencode"; MODEL="openrouter/deepseek/deepseek-v4-flash"
HARNESS_SET=""; MODEL_SET=""; KUBECTL="kubectl"; KUBE=""; NS="homelab"
_srow='{"name":"platform","repos":["homelab"]}'
GW_REPLY_HTTP="200"; GW_REPLY_BODY=""
. "$REPLAY_WORLD/vars.sh"
curl() {
  local _o="" _d="" _m="POST" _u="" _prev=""
  for _a in "$@"; do
    case "$_prev" in -o) _o="$_a";; -d) _d="$_a";; -X) _m="$_a";; esac
    case "$_a" in http*) _u="$_a";; esac
    _prev="$_a"
  done
  printf 'CALL curl %s %s%s\n' "$_m" "$_u" "${_d:+ $_d}" >> "$REPLAY_ACTIONS"
  [ "$_m" = "DELETE" ] && return 0
  if [ "$GW_REPLY_HTTP" = "000" ]; then printf '000'; return 7; fi
  [ -z "$_o" ] || printf '%s' "$GW_REPLY_BODY" > "$_o"
  printf '%s' "$GW_REPLY_HTTP"
}
