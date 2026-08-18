# ── bridge ── the pre-gate launcher state for a claude-harness ride whose pod command is NEITHER
# the recipe/worker shape (`--model <id> `) NOR the `claude -p ` --run shape (here: a goose-style
# --run string on a claude harness). `_claude_model` unset, exactly as for any --run dispatch.
# The failover must NOT announce a rail it cannot thread: it defers, report-only, exit 0 — the
# same burn-saver contract as the both-latched row. `bash` is shadowed as the ladder seam, `curl`
# as a Go-probe tripwire.
HARNESS="claude"
MODEL="haiku"
PROJECT="test-project"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
RUN_CMD="goose run --recipe /tmp/fix-recipe.yaml --params issue=42"
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
