# ── bridge ── review-reflex.sh dispatch-loop state for the assembly-review-dispatch clause.
log() { printf '%s\n' "$*" >> "$REPLAY_ACTIONS"; }
