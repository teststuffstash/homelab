# ── bridge ── the invocation is identical to fixtures/goal-budget-refusal-first-touch/bridge.sh and
# to the interleaved one; only the recorded WORLD differs. Here the numbers have NOT moved since the
# refusal already on the thread — the same $1.75 > $1, the same rows.
. "$REPLAY_ROOT/agents/machine-comment.sh"

ORG=teststuffstash
PROJECT=circles
GOAL_PARENT=29
GB_SUM=1.75
GB_BUDGET=1
GB_ROWS='    #35 → $0.75 (actual spend, ledger)\n    #36 → $1.00 (cap reservation, live key)\n'
