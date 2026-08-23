# Observation point: render_env_card() with a GROUND_RULES_FILE that does not exist — the
# degrade leg. Same env shape as env-card-machine-markers-capture, minus the real file.
GROUND_RULES_FILE="/nonexistent/ground-rules.md"

ROUND=1
ROUNDS_MAX=3
HARNESS="claude"
EGRESS_ENFORCE="true"
DOCKER=""
BASE_REF="master"

render_env_card
