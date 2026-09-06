# ── post ── extract relevant output for expectation checking.
# The key finding: trigger (b) either dispatches a goal-checkpoint unit, or is debounced.
# First run (empty orphans) = first ride, should dispatch.
# Second run (debounce orphans) = second ride, should be debounced.
echo "units: $(printf '%s\n' "$units" | grep -c 'goal-checkpoint' || echo 0)"
echo "orphans_debounced: $(printf '%s\n' "$orphans" | grep -c 'DEBOUNCED' || echo 0)"
