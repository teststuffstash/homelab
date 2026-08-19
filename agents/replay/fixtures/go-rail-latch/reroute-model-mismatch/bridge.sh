# ── bridge ── reproduce issue #629: MODEL and RUN_CMD mismatch
# This scenario sets up a Go-rail dispatch where the degrade check must update both
# RUN_CMD and MODEL. The fixture verifies they stay in sync.
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
# Simulate what model_id.py would do for an opencode-go/deepseek-v4-flash model
MODEL_MODEL="opencode-go/deepseek-v4-flash"
MODEL_HARNESS="claude"
GOOSE_MODEL="opencode-go/deepseek-v4-flash"
# _claude_model is set by harness-run-cmd (line 961): captures MODEL and optionally collapses it
# For opencode-go/*, it stays as-is (line 965)
_claude_model="opencode-go/deepseek-v4-flash"
# RUN_CMD is built with the model (line 976). This is the state before degrade.
RUN_CMD="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200 --append-system-prompt-file /tmp/fix-recipe.yaml 'test command'"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
# Simulate proxy returning a CAPACITY-limited response
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # Return a capacity limit (observed-429 reason, per #629 reproduction)
  printf '{"limited": true, "reason": "observed-429"}'
}
# Ensure the Go arm never consults Anthropic latch
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  echo "TRIPWIRE: the Go arm consulted the Anthropic latch" >&2
  exit 9
}
