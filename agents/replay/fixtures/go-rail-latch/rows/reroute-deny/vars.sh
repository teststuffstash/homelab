# Same shape as the reroute happy path, but the stack row modelDenys claude/haiku (the
# fallback). The Go arm must respect the claim's deny exactly as the M12 block does.
MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","modelDeny":["claude/haiku"]}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
