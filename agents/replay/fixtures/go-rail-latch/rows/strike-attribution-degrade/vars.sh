# Issue #660 leg 2: STRUCK_MODEL divergence across degrade (PR#668 round 2).
MODEL="opencode-go/deepseek-v4-flash"
STRUCK_MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
