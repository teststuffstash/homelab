# ── bridge ── the launcher state the block reads after a headless /sessions ride, as a platform
# tasked ride (issue-42, round 1) that ended; each row overrides from $REPLAY_WORLD/vars.sh.
GW_SESSIONS="1"; GW_SESSION_ID="0123abcd"; GW_URL="http://agent-gateway.agent-egress.svc.cluster.local:8080"
PROJECT="homelab"; TASK="issue-42"; ROUND="1"; NS="homelab"; POD="agent-homelab-issue-42-r1"; KUBECTL="kubectl"; KUBE=""
STRIKE_APPLIES="1"; STRIKE_LINE=""; STRIKE_BY_POD="false"; ERR_CLASS=""; KEY_RETRY_LINE=""; STATS=""; WORK_BRANCH=""
ORIG_ARGS=(--project homelab --task issue-42 --round 1 --recipe .agents/fix.yaml)
RUNLOG="$(mktemp)"; GW_REPLY_STRIKE="null"; GW_OUTCOME_FAILS=""; POD_PHASE="Failed"
. "$REPLAY_WORLD/vars.sh"
gw_auth_header() { printf 'Authorization: Bearer fake-caller-token-projected\n'; }
gw_release() { printf 'CALL gw_release %s\n' "$GW_SESSION_ID" >> "$REPLAY_ACTIONS"; GW_SESSION_ID=""; }
kubectl() { printf '%s' "$POD_PHASE"; }
bash() { printf 'CALL bash %s [AGENT_GATEWAY_ATTEMPT=%s]\n' "$*" "${AGENT_GATEWAY_ATTEMPT:-}" >> "$REPLAY_ACTIONS"; return 0; }
curl() {
  local _d="" _u="" _prev=""
  for _a in "$@"; do
    case "$_prev" in -d) _d="$_a";; esac
    case "$_a" in http*) _u="$_a";; esac
    _prev="$_a"
  done
  printf 'CALL curl POST %s %s\n' "$_u" "$_d" >> "$REPLAY_ACTIONS"
  [ -z "$GW_OUTCOME_FAILS" ] || return 22
  printf '{"id":"0123abcd","outcome":{"class":"x"},"strike":%s,"refuted":0,"replay":false}' "$GW_REPLY_STRIKE"
}
