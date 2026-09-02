# ── bridge ── the per-repo loop variables the C4/C5 clause already holds by the time the
# ambig-decidable check runs. Every name is a SCAN name (`slug`, `repo`, `inprog`, `BODIES`,
# `c6g_nums`, `goalbased_nums`, `dispatchable`, `c4c5_cleared`, `orphans`, `units`) — a bridge that
# invents one pins a different clause.
#
# `inprog` and `BODIES` arrive as recorded files rather than stubbed calls because the enclosing
# loop fetches both far above the block under replay (the `gh issue list` at the top of the repo
# loop, and the open-PR body read at the head of the C4/C5 clause). The pod probes that gate the
# whole clause are the same story: this fixture's world is "no live worker pod, no open PR", which
# is the state the block is only ever reached in.
#
# `goalbased_nums` includes #329 (a goal child) but not #330 (a plain in-progress issue).
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
c6g_nums=""
goalbased_nums="329"
c4c5_cleared=""
orphans=""
units=""
resumable_branches=""
BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies.json")"
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
# ITEM_CLASS_ROWS accumulator — initialized here so the extracted clause block can append to it.
ITEM_CLASS_ROWS=""
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
# item_class_push is NOT stubbed here — the no-strike world must verify that strike-held rows
# are pushed for undecidable C4/C5 goal children (FU-199 / #1240).
# Define the function so the extracted clause block can call it.
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}