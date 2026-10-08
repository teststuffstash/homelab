# ── bridge ── the per-repo loop variables the changes-requested clause reads and writes.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
# The scan sources agents/pr-last-edited.sh at its top (the body-edit leg of the hold reads through it).
. "$REPLAY_ROOT/agents/pr-last-edited.sh"
orphans=""
units=""
# ── stubs ── variables and functions the changes-requested clause reads from the enclosing scope.
WIPPODS_JSON='{"items":[]}'
wip_busy=""
openall='[]'
sess_holds() { return 1; }
item_class_push() { :; }
