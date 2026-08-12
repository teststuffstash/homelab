# ── bridge ── same shape as fixtures/goal-budget-refusal-first-touch/bridge.sh, and the invocation
# is held CONSTANT across the family on purpose: what differs between these four fixtures is the
# recorded WORLD, which is where the bug lived.
. "$REPLAY_ROOT/agents/machine-comment.sh"

ORG=teststuffstash
PROJECT=circles
GOAL_PARENT=29
# The numbers have MOVED since the refusal already on the thread ($1.50 → $1.75): #35 settled to a
# real ledger charge and #36's key went live. Same decision asked of the human, different arithmetic
# under it — which is exactly the case the prefix-only dedup (option 1 on #361) would have left
# showing a stale $1.50 forever.
GB_SUM=1.75
GB_BUDGET=1
GB_ROWS='    #35 → $0.75 (actual spend, ledger)\n    #36 → $1.00 (cap reservation, live key)\n'
