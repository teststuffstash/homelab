# ── bridge ── the capacity-reroute for an un-threadable pod command (a goose-style --run string
# on a claude harness). `_claude_model` unset. The reroute must NOT announce a rail it cannot
# thread: it defers, report-only, exit 0.
HARNESS="claude"
MODEL="opencode-go/deepseek-v4-flash"
PROJECT="test-project"
TASK="issue-42"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
RUN_CMD="goose run --recipe /tmp/fix-recipe.yaml --params issue=42"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '{"limited": true, "reason": "window-weekly"}'
}
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  echo "TRIPWIRE: the Go arm consulted the Anthropic latch" >&2
  exit 9
}
