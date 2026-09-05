# Observation point: call render_env_card() with the required environment variables. Mirrors
# env-card-mcp-present/post.sh's shape (common defaults + the call) rather than sharing it by
# reference — that file pins DOCKER="" unconditionally, so a DOCKER=1 pre.sh would be clobbered.
GROUND_RULES_FILE="${GROUND_RULES_FILE:-$REPLAY_ROOT/agents/ground-rules.md}"

ROUND=1
ROUNDS_MAX=3
HARNESS="claude"
EGRESS_ENFORCE="true"
BASE_REF="master"

# Call the function
render_env_card
