# ── bridge ── the per-queued-issue loop variables for the deps-resolve block.
# Every name here is a SCAN variable the enclosing loop sets (dep, dnum, dslug, slug, repo,
# blocked, stale, orphans, qcycles), never a harness invention.
#
# The scenario: queued issue S has a dependency E (#42) that is CLOSED with
# stateReason=DUPLICATE. E's canonical issue C (other#99) is OPEN → S stays parked.

slug="$IN_SLUG"
repo="$IN_REPO"
dep="homelab#42"
dnum="42"
dslug="$slug"
blocked=""
stale=""
orphans=""
qcycles=""
qnum="100"
qtitle="Test blocked-by-duplicate issue"

# ── stub ── the scan accumulates rows across a whole pass and flushes one POST per
# (tick, namespace) after the stacks loop, so a harness running one extracted block has no
# flush to assert on. Shim it to capture calls instead.
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$REPLAY_ACTIONS"
}

# ADR-125: `item_class_push` rows carry the item's LANE base.
qbase="${qbase:-master}"