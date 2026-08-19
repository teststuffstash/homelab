# ── bridge ── the pre-gate launcher state for a claude-harness worker ride on the Go rail that
# will degrade to subscription fallback due to Go capacity limits. Setup mirrors the reroute
# fixture (MODEL is opencode-go/*, RUN_CMD is pre-baked with it), but this fixture's assertion
# checks STRUCK_MODEL divergence (STRUCK_MODEL stays at pre-degrade value while MODEL/GOOSE_MODEL
# change to the fallback). The strike comment must name the originally attempted entry, not the
# fallback that replaced it.
HARNESS="claude"
MODEL="opencode-go/deepseek-v4-flash"
STRUCK_MODEL="opencode-go/deepseek-v4-flash"  # initialized at line 485 before the gate
PROJECT="test-project"
TASK="issue-42"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # Same capacity-limited condition as reroute: Go window latched, subscription fallback enabled
  printf '{"limited": true, "reason": "window-weekly"}'
}
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  echo "TRIPWIRE: the Go arm consulted the Anthropic latch" >&2
  exit 9
}
