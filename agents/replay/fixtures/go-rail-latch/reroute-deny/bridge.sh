# ── bridge ── same shape as the reroute happy path, but the stack row modelDenys claude/haiku
# (the fallback). The Go arm must respect the claim's deny exactly as the M12 block does.
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
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","modelDeny":["claude/haiku"]}'
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '{"limited": true, "reason": "window-weekly"}'
}
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  echo "TRIPWIRE: the Go arm consulted the Anthropic latch" >&2
  exit 9
}
