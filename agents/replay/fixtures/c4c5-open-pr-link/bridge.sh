# ── bridge ── the per-repo loop variables the C4/C5 clause already holds by the time the selector
# runs. Every name is a SCAN name (`slug`, `repo`, `inprog`, `BODIES`, `c6g_nums`, `goalbased_nums`,
# `c6db_nums`, `sess_nums`, `dispatchable`, `c4c5_cleared`, `orphans`, `units`) — a bridge that
# invents one pins a different clause.
#
# `inprog` and `BODIES` arrive as recorded files rather than stubbed calls because the enclosing
# loop fetches both far above the block under replay (the `gh issue list` at the top of the repo
# loop, and the open-PR body read at the head of the C4/C5 clause). The pod probe is the same
# story: this family's world is "no live worker pod", which is the state the selector is only ever
# reached in for an abandoned ride.
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
c6g_nums=""
goalbased_nums=""
c6db_nums=""
sess_nums=""
c4c5_cleared=""
infeas_done=""
orphans=""
units=""
# The FU-199 resumable set the `c4c5-derivations` block appends to when a goal child's newest
# `AGENT_STRIKE:` comment carries a `Resumable branch pushed:` line. Initialized here because the
# block appends with `+=`, so an unset name is an unbound-variable death under `set -u`.
resumable_branches=""
BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-open.json")"
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
# No live worker pod for the issue: the abandoned-ride state the selector judges.
PODS=""
# ── stub ── the scan accumulates board rows during a pass and flushes one POST per (tick,
# namespace), so a harness running one extracted block has no flush to assert on. The accumulator
# is NOT stubbed away: the `phantom` row the clause pushes is part of its contract, so the family
# observes it.
ITEM_CLASS_ROWS=""
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
