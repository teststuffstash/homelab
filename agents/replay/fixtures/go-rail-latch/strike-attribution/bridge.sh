# ── bridge ── pre-gate state: an opencode-go dispatch that will fail with quota 429
HARNESS="opencode"
MODEL="opencode-go/deepseek-v4-flash"
PROJECT="test-project"
TASK="issue-42"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
RUN_CMD="opencode --model opencode-go/deepseek-v4-flash"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
# Fallback model when capacity is down
AGENT_SUBSCRIPTION_FALLBACK_MODEL="claude/haiku"
# Mocked curl for the router probe
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # Simulate Go capacity limited
  printf '{"limited": true, "reason": "window-weekly"}'
}
