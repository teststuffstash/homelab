# ── bridge ── the per-repo loop variables the agent/review phantom belt holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `BODIES`, `review_only`, `dispatchable`,
# `c4c5_cleared`, `infeas_done`, `orphans`, `units`) — a bridge that invents one pins a different
# clause.
#
# `BODIES` and `review_only` arrive as recorded files rather than stubbed calls because the
# enclosing loop fetches both far above the block under replay. The pod probes that gate the whole
# C4/C5 clause are the same story: this fixture's world is "no live worker pod, no open PR", which
# is the state the block is only ever reached in.
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
c4c5_cleared=""
infeas_done=""
orphans=""
units=""
BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies.json")"
review_only="$(cat "$REPLAY_WORLD/gh/review-only.json")"
# C4C5_PERSIST_S is set by the scan's own config; provide a value for replay.
C4C5_PERSIST_S=300