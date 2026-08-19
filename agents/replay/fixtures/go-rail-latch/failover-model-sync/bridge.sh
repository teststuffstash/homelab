# ── bridge ── PR#643 r1: the SIBLING arm of #629 — an Anthropic-primary ride whose subscription
# is latched fails over to the Go rail (`*)` default arm, #439 leg 2). MODEL is re-pointed at the
# rail; GOOSE_MODEL must move WITH it (it was computed pre-failover and feeds the pod-manifest env
# the strike/stats readers compare — the same divergence #629 fixed on the opencode-go/* arm).
HARNESS="claude"
MODEL="claude/haiku"
PROJECT="test-project"
TASK="issue-42"
HERE="."
PROXY_URL=""
OR_CREDITS=""
OR_MIN="0.25"
AGENT_CREDIT_GATE="1"
AGENT_EGRESS_PROXY="http://proxy.test:8080"
MODEL_MODEL="claude/haiku"
MODEL_HARNESS="claude"
GOOSE_MODEL="haiku"
_claude_model="haiku"
# worker/recipe shape: carries `--model haiku ` so the threading swaps it in place
RUN_CMD="claude -p --model haiku --dangerously-skip-permissions --max-turns 200 --append-system-prompt-file /tmp/fix-recipe.yaml 'test command'"
_srow='{"name":"platform","workerModel":"claude/haiku"}'
# curl: recorder only — this arm's capacity read goes through subscription-latch.sh, not curl
curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  printf '{"limited": false}'
}
# subscription-latch.sh --pick-rail: Anthropic latched, Go clear → the rail id on stdout
bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in
    *subscription-latch.sh*--pick-rail*) printf 'opencode-go/deepseek-v4-flash';;
    *) echo "TRIPWIRE: unexpected bash call: $*" >&2; exit 9;;
  esac
}
