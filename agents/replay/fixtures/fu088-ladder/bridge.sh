# ── bridge ── the pre-gate launcher state for a claude-harness ride: HARNESS/MODEL as dispatched,
# plus the PR#407 `_claude_model` / RUN_CMD values the harness-run-cmd block baked ABOVE this gate
# (the ladder must re-point RUN_CMD at the Go model IN PLACE, never rebuild it). Three pod-command
# SHAPES recur across the family, and each row names its own via the `world` column:
#   worlds/worker-shape     recipe/worker dispatch — RUN_CMD already carries `--model haiku `,
#                            `_claude_model` set (the recipe block at agent-session.sh:946 ran)
#   worlds/retro-run-shape   retro-session.sh:104's `--run` string — `claude -p ` with NO --model
#                            flag at all, `_claude_model` never assigned
#   worlds/goose-run-shape   a goose `--run` string on a claude harness — neither shape
# `claude_model.txt` is present in a world only where the launcher would actually have set
# `_claude_model`; a missing file reads as unset (the `cat` falls back to empty). This is safe to
# encode as an empty STRING rather than a shell-level unset: the one place the block reads it is
# `${_claude_model:-haiku}`, whose `:-` triggers identically on unset and on empty.
#
# `bash` is shadowed as the subscription-latch seam: it serves the --pick-rail verdict
# (`${STUB_RAIL:-anthropic}`, or a failing return when `STUB_RAIL_RC=1` — the both-latched leg) and
# records the call, so a probe that silently stopped happening is a gate that stopped gating.
# `curl` is shadowed so a stray Go probe REDS loudly instead of hanging offline — the `*` arm
# (every non-opencode-go/* claude ride) never consults a rail directly, only the ladder.
HARNESS="claude"
MODEL="haiku"
PROJECT="test-project"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
RUN_CMD="$(cat "$REPLAY_FIXTURE/world/run_cmd.txt")"
_claude_model="$(cat "$REPLAY_FIXTURE/world/claude_model.txt" 2>/dev/null || true)"
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
