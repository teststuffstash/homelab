# ── bridge ── the launcher state the block reads, as a platform (homelab project) ad-hoc ride with
# today's argv defaults; each row overrides from $REPLAY_WORLD/vars.sh. `curl` serves the row's
# gateway answer ($GW_REPLY_HTTP + $GW_REPLY_BODY; HTTP 000 = connection refused, curl exit 7)
# and records every call. A bound answer carries no token; the one row whose gateway answers one
# anyway uses `gws_` + 32 A's — post.sh greps every launcher variable for it.
PROJECT="homelab"; TASK=""; ROUND="1"; HARNESS="opencode"; MODEL="openrouter/deepseek/deepseek-v4-flash"
HARNESS_SET=""; MODEL_SET=""; KUBECTL="kubectl"; KUBE=""; NS="homelab"
RUN_CMD="echo replay"; RECIPE=""   # headless by default (an interactive ride is its own row)
date() { echo 120000; }            # the ad-hoc pod name's clock, pinned (agent-homelab-120000)
_srow='{"name":"platform","repos":["homelab"]}'
GW_REPLY_HTTP="200"; GW_REPLY_BODY=""
# The caller token (GW-SESSIONS-AUTH): by default the pod's projected file, here a temp file holding
# a plain fixture string (never JWT-shaped); a row unsets it via AGENT_GATEWAY_CALLER_TOKEN_FILE.
_gw_tokf="$(mktemp)"; printf 'fake-caller-token-projected' > "$_gw_tokf"
AGENT_GATEWAY_CALLER_TOKEN_FILE="${AGENT_GATEWAY_CALLER_TOKEN_FILE-$_gw_tokf}"
. "$REPLAY_WORLD/vars.sh"
# `kubectl create token` (the jail canary's mint) answers a fixture token and records the call.
kubectl() {
  printf 'CALL kubectl %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in *"create token"*) [ -n "${GW_MINT_FAILS:-}" ] && return 1; printf 'fake-caller-token-minted';; esac
}
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
