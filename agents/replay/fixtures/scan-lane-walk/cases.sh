# The dispatch loop block is composed above this line. `dispatch_succeeded` now means "this pass
# dispatched at least once" (ADR-125 — it no longer ends the pass), and `tried_units` still only
# grows on a skip or an exit-3, so both are printed as the loop's end state.
echo "TEST RESULT: dispatch_succeeded=$dispatch_succeeded, tried_units='$tried_units'"
echo "REACHED: end"
