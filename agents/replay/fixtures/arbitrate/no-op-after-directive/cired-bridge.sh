# ── bridge (homelab#1910, ci-red rows) ── the per-PR loop variables the ci-red clause holds by the
# time its no-op leg runs. Every name is a SCAN variable (`slug`, `repo`, `u`, `u_head`,
# `red_issue`, `head8`, the accumulators); none is a harness invention.
# machine-comment.sh is sourced by the scan at its top; the clock is pinned so the summary-line
# timestamps in the action stream are the fixture's, not the wall clock's.
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "${MC_NOW:?fixture must pin MC_NOW}"; }
slug="$IN_SLUG"
repo="$IN_REPO"
u_head="$IN_HEAD"
red_issue="$IN_ISSUE"
head8="5b353fe9"
orphans=""; units=""; items=""; noop_units=""; red_n=0
# The three gates ABOVE the no-op leg (stale-sha, the human-ruling hold, the footprint belt) have
# their own fixtures (MP-T13); here they are the state the escalation would pass — the re-run
# lives INSIDE them, so each row asserts what replaces the label, not whether a gate holds.
ci_red_should_arbitrate=1
ci_red_belt_skip=0
ci_red_hold_reason=""
ci_red_belt_reason=""
# `openall` = the scan's open-issue listing (labels drive the brief's recipe mapping).
openall="$(cat "$REPLAY_WORLD/gh/openall.json")"
item_class_push() { :; }
# The ci-red clause's per-PR loop, closed by cired-close.sh after the clause blocks.
for u in "$IN_PR"; do
