# ── bridge ── the per-repo loop variables the merge-conflict clause reads. Same shape as the
# clause fixture's bridge; this family reuses it so the debounce half differs only in its world.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
# ── stubs ── variables and functions the merge-conflict clause reads
openall='[]'
WIPPODS_JSON='{"items":[]}'
wip_busy=""
sess_holds() { return 1; }
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }
