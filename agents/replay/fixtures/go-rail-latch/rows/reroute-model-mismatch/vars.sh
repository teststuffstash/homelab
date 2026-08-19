# Issue #629 reproduction: the degrade block must keep RUN_CMD and MODEL (and GOOSE_MODEL) in
# sync — the CAPACITY leg with the recipe/worker RUN_CMD shape and the Go model's 1M context env.
MODEL="opencode-go/deepseek-v4-flash"
TASK="issue-42"
GOOSE_MODEL="opencode-go/deepseek-v4-flash"
_claude_model="opencode-go/deepseek-v4-flash"
RUN_CMD="CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000 claude -p --model opencode-go/deepseek-v4-flash --dangerously-skip-permissions --max-turns 200 --append-system-prompt-file /tmp/fix-recipe.yaml 'test command'"
_srow='{"name":"platform","workerModel":"opencode-go/deepseek-v4-flash"}'
# observed-429 (homelab#600's other CAPACITY reason, per #629's reproduction)
CURL_LIMIT_BODY='{"limited": true, "reason": "observed-429"}'
