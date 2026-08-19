# The capacity-reroute for the `--run` dispatch shape: the pod command carries NO `--model`
# flag at all, and `_claude_model` is UNSET. The reroute must insert `--model haiku` after
# `claude -p ` — the leg-2 run-shape fixture's shape, transposed.
MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
RUN_CMD="printf '%s' 'Zm9v' | base64 -d > /tmp/retro-brief.md; claude -p --dangerously-skip-permissions --max-turns 200 'write the session retro'"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
CURL_LIMIT_BODY='{"limited": true, "reason": "window-weekly"}'
