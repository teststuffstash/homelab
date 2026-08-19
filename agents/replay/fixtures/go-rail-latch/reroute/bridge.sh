# ── bridge ── the pre-gate launcher state for a claude-harness worker ride on the Go rail:
# MODEL is the dispatched opencode-go id, and the PR#407 _claude_model / RUN_CMD values the
# harness-run-cmd block baked ABOVE this gate (the reroute must re-point RUN_CMD at the
# subscription fallback in place, exactly like the #439 leg-2 failover). `curl` is shadowed as
# the /opencode-limit seam (recorded — a probe that silently stopped happening is a gate that
# stopped gating); `bash` is shadowed as a TRIPWIRE (the Go arm must never reach
# subscription-latch.sh). `_srow` is a minimal stack row with the fallback ENABLED (no
# subscriptionFallback:false, no modelDeny hit).
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
RUN_CMD="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # CAPACITY — a utilization-<window> latch (the anthropic arm's reason shape, transposed to the
  # Go windows 5h/7d/30d). Deferring on this parks every Go-primary dispatch for the whole
  # window; the launcher must reroute.
  printf '{"limited": true, "reason": "window-weekly"}'
}
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  echo "TRIPWIRE: the Go arm consulted the Anthropic latch" >&2
  exit 9
}
