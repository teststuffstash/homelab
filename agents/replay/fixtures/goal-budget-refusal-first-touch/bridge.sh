# ── bridge ── source the SHIPPED helper from the checkout and redefine NOTHING but the launcher
# variables the block reads. The find-or-create arithmetic is the thing under test (see
# agents/replay/README.md §When a clause depends on a sourced helper), so the three I/O seams
# `mc_gh_comments` / `mc_gh_comment_create` / `mc_gh_comment_patch` stay real and go through the
# PATH-shim `gh` — which is exactly what puts the create-vs-patch-vs-nothing decision into the
# asserted action stream.
. "$REPLAY_ROOT/agents/machine-comment.sh"

# The four values goal_budget_read leaves behind on the `exhausted` verdict, plus the goal and the
# stack, exactly as agent-session.sh sets them upstream. The sum/rows shape is goal-budget.sh's own
# (`GB_ROWS` is \n-escaped, rendered with printf '%b').
ORG=teststuffstash
PROJECT=circles
GOAL_PARENT=29
GB_SUM=1.75
GB_BUDGET=1
GB_ROWS='    #35 → $0.75 (actual spend, ledger)\n    #36 → $1.00 (cap reservation, live key)\n'
