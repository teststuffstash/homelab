# ── observation point ── not launcher code. The two switches the pod builder and the card read, and
# the card's own Docker bullet (cut at its first sentence — the rest is the env-card-* fixtures').
printf 'DOCKER:[%s]\n' "$DOCKER"
printf 'DOCKER_BY_PATH:[%s]\n' "$DOCKER_BY_PATH"
GROUND_RULES_FILE="${GROUND_RULES_FILE:-$REPLAY_ROOT/agents/ground-rules.md}"
ROUND=1; ROUNDS_MAX=5; HARNESS="goose"; MODEL="deepseek/deepseek-v4-flash"; EGRESS_ENFORCE="true"; SPECS_PROCESS=""
render_env_card | grep -F -- '- **Docker: ' | cut -c1-150
