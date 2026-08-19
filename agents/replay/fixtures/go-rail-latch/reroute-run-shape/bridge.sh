# ── bridge ── the capacity-reroute for the `--run` dispatch shape: the pod command carries NO
# `--model` flag at all, and `_claude_model` is UNSET. The reroute must insert
# `--model haiku` after `claude -p ` — the leg-2 run-shape fixture's shape, transposed. `curl`
# is the /opencode-limit seam (capacity reason); `bash` is the Anthropic-latch tripwire.
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
RUN_CMD="printf '%s' 'Zm9v' | base64 -d > /tmp/retro-brief.md; claude -p --dangerously-skip-permissions --max-turns 200 'write the session retro'"
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
