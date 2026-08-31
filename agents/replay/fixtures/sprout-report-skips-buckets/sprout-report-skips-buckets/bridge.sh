# ── bridge ── the two per-repo loop variables the 🌱 slice reads and writes.
slug="$IN_SLUG"
repo="$IN_REPO"
orphans=""

# ── stub ── item_class_push is defined in the item-class block; the sprout-report block calls it
# but this fixture tests only the sprout-report logic. Shim to capture calls instead.
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}
