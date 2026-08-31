# ── bridge ── the per-repo loop variables the changes-requested clause reads. Every name is a SCAN
# variable set earlier in the per-repo loop (`slug`, `repo`, `prsjson`, `orphans`, `units`), never
# a harness invention — a bridge that renames things pins a different clause.
#
# `prsjson` is the `gh pr list` payload the scan already holds by the time the block runs, so it
# arrives as a recorded world file rather than a stubbed call. `slug`/`repo` come from the env so
# the fixtures can reuse one world across the family.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
# ── stubs ── variables and functions the changes-requested clause reads from the enclosing scope.
# The FU-146 per-item hold (live worker pod check) and the BLOCKED-SOURCE hold both key on the
# PR's linked issue; this PR has no `Fixes #N` link, so both fall through. The WIP gate is clear.
# The reviewable_again probe runs against the recorded pr-view world.
WIPPODS_JSON='{"items":[]}'
wip_busy=""
sess_holds() { return 1; }
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }