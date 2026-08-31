# ── bridge ── the three per-repo loop variables the visibility slice reads and writes.
slug="$IN_SLUG"
repo="$IN_REPO"
orphans=""

# ── stub ── item_class_push is defined in the item-class block; the sprout-report block calls it
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}
