# ── bridge ── the variables the two blocks read, named as retro-session.sh sets them upstream
# (STACK/CELL off argv, PROJECT from retro-project.sh, RUN_ID/BRIEF/RUN/REVIEW from the assembly).
HERE="$REPLAY_ROOT/agents"
STACK="${STACK:?fixture must pin STACK}"; CELL="${CELL:?fixture must pin CELL}"
PROJECT="openrouter-operator"; RUN_ID="r10"; REVIEW="${REVIEW:-}"
BRIEF="$REPLAY_ROOT/agents/replay/fixtures/retro-gateway-cell/brief.md"
RUN="claude -p 'Read /tmp/retro-brief.md'"
date() { echo 2026-11-02; }
# The hand-off seam: the agent-session.sh call, recorded with the gateway env it was given; it exits
# the row's HANDOFF_RC (75 = agent-session.sh's FU-270 transition-fallback exit).
bash() {
  printf 'CALL bash %s [AGENT_GATEWAY=%s AGENT_GATEWAY_ROLE=%s AGENT_GATEWAY_FALLBACK_EXIT=%s]\n' \
    "${*#"$REPLAY_ROOT"/}" "${AGENT_GATEWAY:-}" "${AGENT_GATEWAY_ROLE:-}" "${AGENT_GATEWAY_FALLBACK_EXIT:-}" >> "$REPLAY_ACTIONS"
  return "$HANDOFF_RC"
}
