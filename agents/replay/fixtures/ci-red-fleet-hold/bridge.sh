# ── bridge ── the per-PR loop variables the ci-red-fleet-hold block reads. Every name is a SCAN
# variable set earlier in the ci-red clause (`slug`, `repo`, `u`, `u_head`, `default_branch`,
# `orphans`, `units`, `items`, `red_n`), never a harness invention — a bridge that renames things
# pins a different clause.
#
# `CI_FAILED_JOB_STEP_JQ` is deliberately NOT set here: it arrives as the extracted
# `block:ci-red-fleet-hold` part, so this fixture cannot go green against a transcribed copy of
# the very jq the change is about (#166).
#
# The 24 h fleet-class window is the scan's own knob (`CI_HOLD_CUTOFF`, defaulted in the block to
# `date -u -d '24 hours ago'`) and the family pins it in `env:` — the window is a recorded fact,
# not the day the suite happens to run.
slug="$IN_SLUG"
repo="$IN_REPO"
default_branch="master"
# Per-scan accumulators (the scan's own names).
orphans=""
units=""
items=""
red_n=0
rclause=""
ITEM_CLASS_ROWS=""
item_class_push() { ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${1}|${2}|${3}|${4}\n"; }
# The ci-red clause's per-PR loop. `IN_PRS` is comma-separated so one row drives the r5 three-PR
# world (PR#1540/#1541/#1545) and another a single PR — the loop is the scan's, not the harness's.
for u in $(printf '%s' "$IN_PRS" | tr ',' ' '); do
  u_head="fix/issue-${u}-x"
  head8="aaaaaaaa"
  red_issue=""
  # The ordinary-path products the dispatch leg reads (the negative rows run it).
  red_rounds=0
  red_rounds_key="PR #${u}"
  RED_MAX=5