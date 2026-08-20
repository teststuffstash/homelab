# Issue #674: STRUCK_MODEL for claude/* prefixed chain entry should record the full prefixed id.
HARNESS="claude"
MODEL="claude/haiku"
TASK="issue-42"
CURL_LIMIT_BODY='{"limited": false}'
BASH_PICK_RAIL="claude"
_srow='{"name":"platform","workerModel":"claude/haiku"}'
_claude_model="claude/haiku"
RUN_CMD="claude -p --model claude/haiku --dangerously-skip-permissions --max-turns 200"
