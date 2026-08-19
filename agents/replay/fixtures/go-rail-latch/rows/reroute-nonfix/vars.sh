# Same shape as the reroute happy path, but NO TASK (adhoc dispatch). The capacity reroute
# must leave a non-fix ride to the gates below.
MODEL="opencode-go/deepseek-v4-flash"
TASK=""
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
