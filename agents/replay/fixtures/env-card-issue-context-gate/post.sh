# Observation point: render the card twice — the two arms of the TASK gate — so the single
# action stream carries both the positive and the negative assertion. One dir, because the
# ADR-103 pin-vacuity gate (homelab#1107) runs each changed fixture dir against the BASE tree
# and a negative-only arm cannot red there: the Issue-context line is new in this PR.
GROUND_RULES_FILE="${GROUND_RULES_FILE:-$REPLAY_ROOT/agents/ground-rules.md}"

ROUND=1
ROUNDS_MAX=3
HARNESS="goose"
MODEL="deepseek/deepseek-v4-flash"
EGRESS_ENFORCE="true"
DOCKER=""
BASE_REF="master"

echo "── arm: issue-task (TASK=issue-1175) — the Issue-context line IS emitted"
TASK="issue-1175"; ISSUE_N="1175"
render_env_card
echo "── arm: research-task (TASK=research-1175-fanout, ISSUE_N=1175) — it is NOT emitted"
TASK="research-1175-fanout"; ISSUE_N="1175"
render_env_card