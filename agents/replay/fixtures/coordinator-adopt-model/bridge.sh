# ── bridge ── common state for every coordinator-adopt-model leg; each row's varying state
# (RESOLVED, RESOLVE_CLASS, GOAL_MODEL, INITIAL_MODEL) is sourced from
# $REPLAY_WORLD/vars.sh — the row's `rows/<id>/vars.sh` overlay.
HERE="$REPLAY_ROOT/agents"
. "$REPLAY_WORLD/vars.sh"

# Set the initial MODEL value (what MODEL was before the adoption block runs).
# The adoption block only changes MODEL when RESOLVED is non-empty; otherwise MODEL
# stays at this initial value.
MODEL="${INITIAL_MODEL:-sonnet}"

# Export so the block and stubs see them.
export HERE RESOLVED RESOLVE_CLASS GOAL_MODEL MODEL REPLAY_ACTIONS REPLAY_WORLD