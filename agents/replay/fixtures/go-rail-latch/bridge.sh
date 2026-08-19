# ── bridge ── launcher state common to every go-rail-latch leg (constants that never differ
# across rows: no fixture flips harness/proxy shape); each row's varying state (MODEL, TASK,
# RUN_CMD, _srow, GOOSE_MODEL/_claude_model, the /opencode-limit reply, the --pick-rail reply)
# is sourced from $REPLAY_WORLD/vars.sh — the row's `rows/<id>/vars.sh` overlay (family contract
# in fixture.yaml). `curl` is shadowed as the /opencode-limit seam (recorded — a probe that
# silently stopped happening is a gate that stopped gating), driven by the row's
# `$CURL_LIMIT_BODY`. `bash` is shadowed as a TRIPWIRE — the Go arm must never reach
# subscription-latch.sh — except when the row sets `$BASH_PICK_RAIL` (the `*)` default-arm
# failover leg), in which case a `--pick-rail` call returns it instead of tripping.
HARNESS="claude"
PROJECT="test-project"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
. "$REPLAY_WORLD/vars.sh"

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '%s' "$CURL_LIMIT_BODY"
}
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *subscription-latch.sh*--pick-rail*)
      if [ -n "${BASH_PICK_RAIL:-}" ]; then printf '%s' "$BASH_PICK_RAIL"; return 0; fi ;;
  esac
  echo "TRIPWIRE: the Go arm consulted the Anthropic latch" >&2
  exit 9
}
