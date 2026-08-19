# PR#643 r1 (the #629 sibling): an Anthropic-primary ride (MODEL=claude/haiku, the `*)` default
# arm) whose subscription is latched fails over to the Go rail. GOOSE_MODEL/_claude_model are
# the pre-failover values the block must move WITH MODEL.
MODEL="claude/haiku"
TASK="issue-42"
GOOSE_MODEL="haiku"
_claude_model="haiku"
# worker/recipe shape: carries `--model haiku ` so the threading swaps it in place
RUN_CMD="claude -p --model haiku --dangerously-skip-permissions --max-turns 200 --append-system-prompt-file /tmp/fix-recipe.yaml 'test command'"
_srow='{"name":"platform","workerModel":"claude/haiku"}'
# curl: recorder only — this arm's capacity read goes through subscription-latch.sh, not curl
CURL_LIMIT_BODY='{"limited": false}'
# subscription-latch.sh --pick-rail: Anthropic latched, Go clear → the rail id on stdout
BASH_PICK_RAIL='opencode-go/deepseek-v4-flash'
