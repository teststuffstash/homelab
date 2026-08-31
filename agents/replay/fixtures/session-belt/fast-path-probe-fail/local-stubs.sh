# ── probe-fail leg only ── the unit FLOWS THROUGH to dispatch here (the sibling holds before it),
# so the dispatch-side seams get recording stubs: the CALL lines are the assertion that the unit
# genuinely proceeded — the launcher atomic gate is the real backstop this leg hands off to.
dispatch_phase() { printf "CALL dispatch_phase %s\n" "$*" >> "$REPLAY_ACTIONS"; }
scan_phase() { printf "CALL scan_phase %s\n" "$*" >> "$REPLAY_ACTIONS"; }

# ── stub ── item_class_push is defined in the item-class block; the unit-fast-path block calls it
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}
