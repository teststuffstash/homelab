# ── observation point ── not launcher code. The switch, the two pod fragments (spliced verbatim
# into the manifest) and the card's own bullet — grep'd out of the full card; the rest of the card
# is the env-card-* fixtures' business. Printing the fragments, never a derived fact, pins the text.
printf 'SPECS_PROCESS:[%s]\n' "$SPECS_PROCESS"
printf 'IV_MOUNT:%s\n' "$IV_MOUNT"
printf 'IV_VOLUME:%s\n' "$IV_VOLUME"
printf 'IV_CARD:[%s]\n' "$IV_CARD"
GROUND_RULES_FILE="${GROUND_RULES_FILE:-$REPLAY_ROOT/agents/ground-rules.md}"
ROUND=1; ROUNDS_MAX=5; HARNESS="goose"; MODEL="deepseek/deepseek-v4-flash"; EGRESS_ENFORCE="true"; DOCKER=""
render_env_card | grep -F -- '- **Spec process' || printf 'card: no spec-process bullet\n'
