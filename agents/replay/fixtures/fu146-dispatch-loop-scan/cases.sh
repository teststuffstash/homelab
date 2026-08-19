# Test arm 1: exit 3 (FU-146 racing refusal)
# The fu146-dispatch-loop block is inserted by the replay runner here.
# With bridge.sh setup: coordinator-session.sh returns 3 on first call, 0 on second
# Expected: dispatch_succeeded=1, tried_units contains issue-100

echo "TEST: exit 3 — racing dispatcher won, should retry next unit"
# [fu146-dispatch-loop block will be inserted here]

echo "TEST RESULT: dispatch_succeeded=$dispatch_succeeded, tried_units='$tried_units'"
echo "REACHED: end"
