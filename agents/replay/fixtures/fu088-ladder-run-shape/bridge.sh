# ── bridge ── retro's REAL dispatch shape (retro-session.sh:104, claude arm): the pod command is
# a `--run` string carrying NO `--model` flag at all, and `_claude_model` is UNSET (the recipe
# block that assigns it at agent-session.sh:946 never ran). The failover must insert
# `--model <go-rail-id>` after `claude -p ` — the round-1 code did a no-op substitution here, left
# the success log, and dispatched a pod running the CLI default against the still-latched API.
# `bash` is shadowed as the subscription-latch seam; `curl` is shadowed so a stray Go probe REDS
# loudly instead of hanging offline.
HARNESS="claude"
MODEL="haiku"
PROJECT="test-project"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
RUN_CMD="printf '%s' 'Zm9v' | base64 -d > /tmp/retro-brief.md; claude -p --dangerously-skip-permissions --max-turns 200 'write the session retro'"
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
