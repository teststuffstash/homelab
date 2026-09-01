# ── bridge ── the per-PR loop variables the round-evidence and ci-red-rounds blocks read. Every
# name is a SCAN variable set earlier in the ci-red clause (`slug`, `repo`, `u`, `u_head`,
# `red_issue`, `head8`, `orphans`, `red_n`), never a harness invention — a bridge that renames
# things pins a different clause.
#
# `STATS_TS_DEF` and `NOOP_ROUND_JQ` are deliberately NOT set here: they arrive as the extracted
# `block:round-evidence` part, so this fixture cannot go green against a transcribed copy of the
# very jq the change is about (#166).
slug="$IN_SLUG"
repo="$IN_REPO"
u="$IN_PR"
# The branch carries the issue id, which is what the issue-keyed ceiling would key on if it ran.
u_head="fix/issue-1108-ci-red-rerun-wake"
# Body-only, and this PR's body has no closing keyword — so `red_key` falls back to the branch.
red_issue=""
# Short head sha for the ci-red-gate report line.
head8="aaaaaaaa"
# Per-scan accumulators.
orphans=""
units=""
red_n=0
items=""
item_class_push() { :; }
# The ci-red-gate block contains a `continue` that must be inside a loop. Wrap it in a single-PR
# for loop matching the scan's per-red-PR loop structure.
for u in "$IN_PR"; do