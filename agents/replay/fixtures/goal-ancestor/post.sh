# ── observation point ── not launcher code. In agent-session.sh the next statement past this block
# is the budget pre-flight, which does `goal_budget_read <slug> "$GOAL_PARENT" …` and then refuses
# or proceeds. `GOAL_PARENT` IS therefore the gate's subject, and printing it here is how a fixture
# asserts on the defect: the number below is the issue whose `Budget:` line gets enforced. The card
# is printed line-prefixed because it is multi-line and the action stream is line-oriented.
echo "GATE SUBJECT: #${GOAL_PARENT:-<none — pre-flight skipped>}"
printf '%s\n' "${GOAL_CARD:-<no card — the ride is goal-blind>}" | sed 's/^/CARD | /'
