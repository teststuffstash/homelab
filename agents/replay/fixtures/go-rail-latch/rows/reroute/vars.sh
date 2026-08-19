# The CAPACITY-limited happy path (homelab#600 launcher half): fallback ENABLED on the stack
# row, no modelDeny hit, class=fix. RUN_CMD carries the recipe/worker `--model <id> ` shape and
# the Go model's 1M context env, both threaded/stripped by the reroute.
MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
