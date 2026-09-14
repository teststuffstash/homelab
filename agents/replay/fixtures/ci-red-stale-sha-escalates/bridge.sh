# ── bridge ── the per-PR loop variables the ci-red clause reads.
# Source machine-comment.sh and pin its clock so mc_event calls are deterministic.
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "${MC_NOW:?fixture must pin MC_NOW}"; }

slug="$IN_SLUG"
repo="$IN_REPO"
u="$IN_PR"
# Branch name (not goal/**, so no exclusion).
u_head="fix/issue-1515-something"
# Linked issue from body (closes #1515).
red_issue="1515"
# Head sha (8-char short form, this is what the check will query per-sha).
head8="5b353fe9"
# Full headRefOid (used by the check).
headRefOid_full="5b353fe9abcdef0123456789abcdef0123456789"
# Attempt count already at MAX (3 rounds completed).
attempts=3
# red_rounds computed to be >= RED_MAX (3), triggering exhausted case.
red_rounds=3
RED_MAX=3
red_rounds_key="issue #1515 (1 PR)"
# noop_round not set (we're not in the noop case, we're in the exhausted case)
noop_round=""
# red_probe data — the fixture mocks provide check-runs with a completed red (lowercase conclusion).
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
