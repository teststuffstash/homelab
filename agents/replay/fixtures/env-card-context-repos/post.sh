# Observation point: render the card with the circles context-repos default, keep the one bullet.
GROUND_RULES_FILE="${GROUND_RULES_FILE:-$REPLAY_ROOT/agents/ground-rules.md}"
CONTEXT_REPOS="https://github.com/teststuffstash/circles-iac.git https://github.com/teststuffstash/homelab.git"
ROUND=1
ROUNDS_MAX=3
HARNESS="goose"
MODEL="deepseek/deepseek-v4-flash"
EGRESS_ENFORCE="true"
DOCKER=""
BASE_REF="master"
render_env_card | grep -F -- '- **Context repos:**'
