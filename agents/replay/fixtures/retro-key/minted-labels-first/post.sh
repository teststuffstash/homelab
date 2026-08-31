# ── observation point ── not retro-session code. It stands in for the `exec bash agent-session.sh
# … "${EXTRA[@]}"` that follows the block, built the same way the launcher builds it. What the ride
# is handed IS the contract: a cell-scoped Secret, or (before #270) nothing at all, which
# agent-session.sh resolves to the project's standing fixer key.
if [ -n "${RETRO_OPENROUTER_SECRET:-}" ]; then
  echo "HANDOFF: agent-session.sh $PROJECT --harness $HARNESS --model $MODEL --openrouter-secret $RETRO_OPENROUTER_SECRET"
else
  echo "HANDOFF: agent-session.sh $PROJECT --harness $HARNESS --model $MODEL (no key — falls back to ${PROJECT}-openrouter)"
fi