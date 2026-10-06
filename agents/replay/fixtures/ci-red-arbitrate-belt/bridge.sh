# ── bridge ── the per-PR loop variables the ci-red clause reads. Every name is a SCAN name
# (`slug`, `repo`, `u`, `red_issue`, `head8`, `red_probe`, `red_rounds`, `RED_MAX`, `noop_round`,
# `orphans`, `units`) — a bridge that invents one pins a different clause.
#
# Source machine-comment.sh (the escalation's mc_event) and footprint.sh (the belt's fp_conflict
# intersection predicate — the ONE home, never a second glob reader here).
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "${MC_NOW:?fixture must pin MC_NOW}"; }
. "$REPLAY_ROOT/agents/footprint.sh"
slug="$IN_SLUG"
repo="$IN_REPO"
u="$IN_PR"
# Branch name (not goal/**, so no exclusion).
u_head="fix/issue-1515-something"
# Linked issue from body (closes #1515) — the belt reads its declared Touches.
red_issue="1515"
# Head sha (8-char short form, this is what the check will query per-sha).
head8="5b353fe9"
# Full headRefOid (used by the per-sha check-runs query).
headRefOid_full="5b353fe9abcdef0123456789abcdef0123456789"
# Attempt count already at MAX (3 rounds completed) — the exhausted case.
attempts=3
red_rounds=3
RED_MAX=3
red_rounds_key="issue #1515 (1 PR)"
# noop_round not set (we're in the exhausted case, not the no-op case).
noop_round=""
# red_probe data — the fixture mocks provide a completed red check on the current head.
red_probe='[
  {
    "number": '"$u"',
    "headRefOid": "'"$headRefOid_full"'",
    "headRefName": "'"$u_head"'"
  }
]'
# Per-scan accumulators.
orphans=""
units=""
red_n=0
items=""
item_class_push() { :; }
# The ci-red clause's per-PR loop. Wrap in a single-PR for loop matching the scan's structure.
for u in "$IN_PR"; do
