# ── bridge ── the pre-gate launcher state for a claude-harness worker/retro ride: HARNESS and
# MODEL as dispatched, and the PR#407 `_claude_model` / RUN_CMD values the harness-run-cmd block
# baked ABOVE this gate (the ladder must re-point RUN_CMD at the Go model in place). `bash` is
# shadowed as the subscription-latch seam: it serves the --pick-rail verdict and records the
# call, so a probe that silently stopped happening is a gate that stopped gating. `curl` is
# shadowed so a stray Go probe REDS loudly instead of hanging offline.
HARNESS="claude"
MODEL="haiku"
PROJECT="test-project"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
_claude_model="haiku"
RUN_CMD="claude -p --model haiku --dangerously-skip-permissions --max-turns 200"
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  echo "TRIPWIRE: the * arm probed a rail directly instead of the ladder" >&2
  exit 9
}
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *subscription-latch.sh*--pick-rail*)
      [ "${STUB_RAIL_RC:-0}" = "1" ] && return 1
      printf '%s\n' "${STUB_RAIL:-anthropic}"
      return 0;;
    *)
      echo "TRIPWIRE: unexpected bash: $*" >&2
      exit 9;;
  esac
}
