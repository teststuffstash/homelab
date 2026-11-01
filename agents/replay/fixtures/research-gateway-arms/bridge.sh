# ── bridge ── the variables the block reads, named exactly as research-fanout.sh sets them above it.
HERE="$REPLAY_ROOT/agents"
PROJECT="homelab"; ISSUE="210"; CLASS="regular"; ARMS="2"; START_SLOT="1"
RECIPE="/workspace/homelab/.agents/research.yaml"
STACK="${STACK:?fixture must pin STACK}"; DRY="${DRY:?fixture must pin DRY}"
ARM_RC_1=0; ARM_RC_2=0; ARM_OUT_1=""; ARM_OUT_2=""; FALLBACK_DRAW="  slot 1: deepseek/deepseek-v4-pro"
[ -f "$REPLAY_WORLD/vars.sh" ] && . "$REPLAY_WORLD/vars.sh"
mktemp() { mkdir -p "$REPLAY_FIXTURE/armlogs"; printf '%s\n' "$REPLAY_FIXTURE/armlogs"; }
sleep() { wait; }
bash() {
  printf 'CALL bash %s [AGENT_GATEWAY=%s ROLE=%s FALLBACK_EXIT=%s CALLER_SA=%s WIP=%s RESEARCH_GATEWAY=%s]\n' \
    "${*#"$REPLAY_ROOT"/}" "${AGENT_GATEWAY:-}" "${AGENT_GATEWAY_ROLE:-}" "${AGENT_GATEWAY_FALLBACK_EXIT:-}" \
    "${AGENT_GATEWAY_CALLER_SA:-}" "${AGENT_WIP_LIMIT:-}" "${RESEARCH_GATEWAY:-}" >> "$REPLAY_ACTIONS"
  case "$1" in
    */agent-session.sh)
      local _slot="${4##*-arm}" _o _r
      eval "_o=\"\${ARM_OUT_${_slot}}\"; _r=\"\${ARM_RC_${_slot}}\""
      [ -z "$_o" ] || printf '%s\n' "$_o"
      return "$_r";;
    */research-fanout.sh) printf '%s\n' "$FALLBACK_DRAW"; return 0;;
  esac
}
