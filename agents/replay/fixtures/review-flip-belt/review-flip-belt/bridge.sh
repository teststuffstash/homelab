# ── bridge ── the per-repo loop variables the review-flip belt holds by the time the block runs.
# Every name is a SCAN name (`slug`, `repo`, `inprog`, `prsjson`, `orphans`, `units`) — a bridge
# that invents one pins a different clause.
#
# `inprog` and `prsjson` arrive as recorded files rather than stubbed calls because the enclosing
# loop fetches both far above the block under replay (the `gh issue list` at the top of the repo
# loop, and the `gh pr list` the ADR-097 open-PR cap reads at line ~904).
slug="teststuffstash/homelab"
repo="homelab"
orphans=""
units=""
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
