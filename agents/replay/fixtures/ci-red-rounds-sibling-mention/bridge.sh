# ── bridge ── the per-PR loop variables the round-evidence block reads. Every name is a SCAN
# variable set earlier in the ci-red clause (`slug`, `repo`, `u`, `u_head`, `red_issue`), never a
# harness invention — a bridge that renames things pins a different clause.
#
# `STATS_TS_DEF` and `NOOP_ROUND_JQ` are deliberately NOT set here: they arrive as the extracted
# `block:round-evidence` part, so this fixture cannot go green against a transcribed copy of the
# very jq the change is about (#166).
slug="$IN_SLUG"
repo="$IN_REPO"
u="$IN_PR"
# The branch carries the issue id, which is what the issue-keyed ceiling would key on.
u_head="fix/issue-19-thing"
# Body-only, and this PR's body has no closing keyword — so `red_key` falls back to the branch.
red_issue=""