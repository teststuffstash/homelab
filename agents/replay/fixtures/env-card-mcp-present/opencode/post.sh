# Observation point: call render_env_card() with the required environment variables.
GROUND_RULES_FILE="${GROUND_RULES_FILE:-$REPLAY_ROOT/agents/ground-rules.md}"

ROUND=1
ROUNDS_MAX=3
HARNESS="opencode"
MODEL="openrouter/deepseek/deepseek-v4-flash"
EGRESS_ENFORCE="true"
DOCKER=""
BASE_REF="master"

# Call the function
render_env_card