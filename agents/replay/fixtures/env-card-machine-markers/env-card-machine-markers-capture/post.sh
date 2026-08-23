# Observation point: call render_env_card() with the required environment variables
# and verify the machine-marker rule is in the output.
#
# GROUND_RULES_FILE points at the REAL agents/ground-rules.md (FU-117, #763) — extraction over
# transcription: the universal bullets are asserted from the shipped file, so a drift between the
# file and this fixture is impossible by construction. The missing-file degrade is its own
# fixture (env-card-ground-rules/missing).
GROUND_RULES_FILE="$REPLAY_ROOT/agents/ground-rules.md"

ROUND=1
ROUNDS_MAX=3
HARNESS="claude"
EGRESS_ENFORCE="true"
DOCKER=""
BASE_REF="master"

# Call the function
render_env_card
