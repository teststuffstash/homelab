# ── bridge ── the per-repo loop variables the C4/C5 clause already holds by the time the
# infeasible terminal runs. Every name is a SCAN name (`slug`, `repo`, `inprog`, `BODIES`,
# `c6g_nums`, `goalbased_nums`, `dispatchable`, `c4c5_cleared`, `orphans`, `units`) — a bridge that
# invents one pins a different clause.
#
# `inprog` and `BODIES` arrive as recorded files rather than stubbed calls because the enclosing
# loop fetches both far above the block under replay (the `gh issue list` at the top of the repo
# loop, and the open-PR body read at the head of the C4/C5 clause). The pod probes that gate the
# whole clause are the same story: this fixture's world is "no live worker pod, no open PR", which
# is the state the block is only ever reached in.
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
c6g_nums=""
goalbased_nums=""
c4c5_cleared=""
orphans=""
units=""
BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies.json")"
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }

# The ONE body-grammar parser (ADR-122 (3), homelab#1460): the C4/C5 class derivation reads the
# block through it, so the bridge points IB_PY at the REAL module in the checkout — the same
# line goal/bridge.sh already carries.
IB_PY="$REPLAY_ROOT/agents/issue_body.py"
