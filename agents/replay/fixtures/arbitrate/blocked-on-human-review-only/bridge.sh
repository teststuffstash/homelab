# ── bridge ── the per-repo loop variables the arbitrate clause reads and writes.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
item_class_push() { :; }