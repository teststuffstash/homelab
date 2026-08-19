# Observation point: call render_env_card() with the required environment variables
# and verify the machine-marker rule is in the output.

ROUND=1
ROUNDS_MAX=3
HARNESS="claude"
EGRESS_ENFORCE="true"
DOCKER=""
BASE_REF="master"

# Call the function
render_env_card
