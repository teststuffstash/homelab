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
# The goal-child set the enclosing loop computed (the FU-143 hold's input). The `strike-marker`
# row declares its members through the table's only per-row channel (`env`), COMMA-separated
# because that column is space-separated and word-split by the harness (the fu146-resumable-quoted
# bridge's `RB_SHAPE` note, one family over) — the family's other rows have no goal children at
# all, so the default is empty and they are unchanged.
goalbased_nums="${GOALBASED_NUMS:-}"
goalbased_nums="${goalbased_nums//,/ }"
c4c5_cleared=""
orphans=""
units=""
# The FU-199 resumable set the `c4c5-derivations` block appends to when a goal child's newest
# `AGENT_STRIKE:` comment carries a `Resumable branch pushed:` line. Initialized here because the
# `strike-marker` row is the first in this family to reach that path (the others have no goal
# children) — the block appends with `+=`, so an unset name is an unbound-variable death.
resumable_branches=""
BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies.json")"
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
# KUBECTL is the path to the kubectl stub, KUBE are kubectl flags (empty in fixtures).
# Needed for the per-issue liveness check added in homelab#2305.
KUBECTL="kubectl"
KUBE=""
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on. The accumulator is NOT
# stubbed away: the `parked-infeasible` board row is part of this clause's contract (homelab#1797
# — the class `agents/board.sh` renders as "AGENT_INFEASIBLE — re-scope needed"), so the family
# observes it. `unit_lane_of` is deliberately not called: it is the production base resolution,
# and a replay composition runs one block without the per-repo pass that feeds it.
ITEM_CLASS_ROWS=""
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
