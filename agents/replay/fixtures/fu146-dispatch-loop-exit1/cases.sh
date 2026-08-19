# Test arm 2: exit 1 (real dispatch error)
# The fu146-dispatch-loop block is inserted by the replay runner here.
# With bridge.sh setup: coordinator-session.sh returns 1 immediately
# Expected: dispatch_rc captures 1, propagates as scan exit (does NOT retry or print FU-146 message)

echo "TEST: exit 1 — real dispatch error, should propagate"
# [fu146-dispatch-loop block will be inserted here]

echo "TEST RESULT: dispatch_succeeded=$dispatch_succeeded, tried_units='$tried_units'"
echo "REACHED: end"
