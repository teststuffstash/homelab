# ── bridge ── the per-repo loop variables the agent/done phantom belt holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `dispatchable`, `orphans`) — a bridge
# that invents one pins a different clause.
#
# `done_closed` and `done_merged` are fetched INSIDE the block via `gh issue list` and `gh pr list`;
# the gh stub serves them from world/gh/ files. The bridge provides the loop context variables.
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
# C4C5_PERSIST_S is set by the scan's own config; provide a value for replay.
C4C5_PERSIST_S=300
ISSUE_LIST_LIMIT=200