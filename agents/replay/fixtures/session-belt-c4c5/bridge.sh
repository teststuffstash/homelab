# ── bridge ── the per-repo loop variables the C4/C5 clause holds by the time the derivations run.
# Every name is a SCAN name (`slug`, `repo`, `inprog`, `BODIES`, `c6g_nums`, `goalbased_nums`,
# `dispatchable`, `c4c5_cleared`, `orphans`, `units`) — a bridge that invents one pins a different
# clause. `inprog` and `BODIES` arrive as recorded files because the enclosing loop fetches both
# far above the block under replay.
#
# `repo` is set BEFORE the session-belt probe block (parts order), so the probe computes
# `sess_busy`/`sess_nums` from the recorded pod list — not hardcoded here.
slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
c6g_nums=""
goalbased_nums=""
c4c5_cleared=""
orphans=""
units=""
LOOP_NS=""
KUBECTL="kubectl"
KUBE=""
BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies.json")"
inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog.json")"
