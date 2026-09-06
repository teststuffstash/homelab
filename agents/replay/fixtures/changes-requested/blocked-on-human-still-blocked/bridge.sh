# ── bridge ── the per-repo loop variables the changes-requested clause reads and writes.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
# ── stubs ── variables and functions the changes-requested clause reads from the enclosing scope.
WIPPODS_JSON='{"items":[]}'
wip_busy=""
openall='[]'
sess_holds() { return 1; }
item_class_push() { :; }
