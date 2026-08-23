# Observation point: call render_env_card() with the required environment variables.
# SHARED across the env-card families (PR#768 review — the byte-identical-post.sh anti-pattern):
# the env-card-ground-rules degrade fixtures compose a tiny pre.sh (setting GROUND_RULES_FILE to
# their degenerate path) BEFORE this file, so the default below only fires when nothing set it —
# here, the REAL agents/ground-rules.md (extraction over transcription: drift between the file
# and the fixture is impossible by construction).
GROUND_RULES_FILE="${GROUND_RULES_FILE:-$REPLAY_ROOT/agents/ground-rules.md}"

ROUND=1
ROUNDS_MAX=3
HARNESS="claude"
EGRESS_ENFORCE="true"
DOCKER=""
BASE_REF="master"

# Call the function
render_env_card
