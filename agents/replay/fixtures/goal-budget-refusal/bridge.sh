# ── bridge ── source the SHIPPED helper from the checkout and redefine NOTHING but the launcher
# variables the block reads. The find-or-create arithmetic is the thing under test (see
# agents/replay/README.md §When a clause depends on a sourced helper), so the three I/O seams
# `mc_gh_comments` / `mc_gh_comment_create` / `mc_gh_comment_patch` stay real and go through the
# PATH-shim `gh` — which is exactly what puts the create-vs-patch-vs-nothing decision into the
# asserted action stream.
#
# The invocation is held CONSTANT across the whole family on purpose (homelab#361's own lesson):
# what differs between the five rows is the recorded WORLD — the goal's existing comment timeline,
# named per row under `rows/<id>/` — not the call. `unreadable` carries no `rows/` overlay at all:
# its world is `STUB_GH=fail` (declared in its row's `env` column), the shape a 403/404/network
# failure takes, which is why that row's world stays empty rather than recording one.
. "$REPLAY_ROOT/agents/machine-comment.sh"

# The four values goal_budget_read leaves behind on the `exhausted` verdict, plus the goal and the
# stack, exactly as agent-session.sh sets them upstream. The sum/rows shape is goal-budget.sh's own
# (`GB_ROWS` is \n-escaped, rendered with printf '%b'). Numbers are the CURRENT scan's arithmetic
# ($1.75 > $1) — current on every row, including the ones whose recorded world still carries an
# older sum on the comment already there (`interleaved`'s $1.50): the property under test is one
# comment AND current arithmetic, never one comment with whatever arithmetic it was first written
# with.
ORG=teststuffstash
PROJECT=circles
GOAL_PARENT=29
GB_SUM=1.75
GB_BUDGET=1
GB_ROWS='    #35 → $0.75 (actual spend, ledger)\n    #36 → $1.00 (cap reservation, live key)\n'
