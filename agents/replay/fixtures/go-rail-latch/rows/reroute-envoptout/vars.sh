# Same shape as the reroute happy path (fallback ENABLED on the row), but the fixture's
# `env:` column sets AGENT_SUBSCRIPTION_FALLBACK=0 — the per-run override. The Go arm must
# read the env knob exactly as the M12 block does.
MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
