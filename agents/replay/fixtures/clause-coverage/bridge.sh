# ── bridge ── the world the clause-coverage case enumerates. Every name is a SCAN name
# (`openall`, `CC_RUN`) — a bridge that invents one pins a different clause.
#
# The world is ONE ISSUE PER ADMISSIBLE STATE (world/gh/issue-list.json) plus the one frozen
# open PR (world/gh/pr-list.json). `openall` is the scan's own open-issue fetch, which the
# lifted `>>>REPLAY:queued-derivation>>>` block reads; the other selectors are run by the
# `>>>REPLAY:clause-coverage>>>` block itself, over the same world.
#
# No `CC_ISSUES_*` seam: the states are the world's issues, and the block reads them from
# `$REPLAY_WORLD` — a hand-passed state string is exactly the retyped copy this case exists
# to replace.
openall="$(cat "$REPLAY_WORLD/gh/issue-list.json")"
# The block is inert in production (the scan never sets CC_RUN); the fixture turns it on.
CC_RUN=1
