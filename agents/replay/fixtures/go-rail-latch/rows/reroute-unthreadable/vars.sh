# The capacity-reroute for an un-threadable pod command (a goose-style --run string on a claude
# harness). `_claude_model` unset. The reroute must NOT announce a rail it cannot thread: it
# defers, report-only, exit 0.
MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
RUN_CMD="goose run --recipe /tmp/fix-recipe.yaml --params issue=42"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
