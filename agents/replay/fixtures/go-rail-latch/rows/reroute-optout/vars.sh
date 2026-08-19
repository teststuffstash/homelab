# Same shape as the reroute happy path, but the stack row OPTS OUT of the fallback
# (`subscriptionFallback: false`). The Go arm must read the knob exactly as the M12 block does
# (== false, never `// false`).
MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","subscriptionFallback":false}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
