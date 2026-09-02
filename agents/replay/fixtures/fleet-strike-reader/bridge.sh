# ── bridge ── the per-repo loop variables the fleet-strike reader holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `dispatchable`, `openall`, `orphans`).
#
# `openall` is the full open-issue list for the repo, fetched far above the block under replay.
# The gh stub serves individual issue comments from world/gh/ files.
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
# openall: four open issues (#326-#329) all with agent-fix label, no agent/error yet
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }