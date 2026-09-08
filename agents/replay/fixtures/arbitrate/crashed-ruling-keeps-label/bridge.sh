# ── bridge ── the per-repo loop variables the arbitrate belt reads and writes.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace).
item_class_push() { :; }
