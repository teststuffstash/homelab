# ── bridge ── same scan state as the sibling fixture (`HERE`, the scan's own `footprint.sh`
# source line, `orphans`). Only `PIN_ONLY_LINT` differs, and it is set through the override the
# shipped script already declares — the fixture changes the WORLD, never the clause.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
orphans=""

# ── stub ── item_class_push is defined in the item-class block; the guarded-hold block calls it
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}
