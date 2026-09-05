# ── bridge ── the per-queued-issue loop variables for the queued-classification block.
# Every name here is a SCAN variable the enclosing loop sets (repo, qnum, qtitle, qtouches,
# qdeps, qpin, qclass, qparent), never a harness invention. qdeps is already normalized to empty
# if "-" by line ~1448, so no normalization needed here.

repo="homelab"
qnum="100"
qtitle="Test queued-ready issue"
qtouches="agents/**"
qdeps=""           # Empty = no blockers → should become queued-ready
qpin="-"           # Not pinned
qclass="fix"       # Default class
qparent=""         # No parent
units=""
punits=""

# ── stub ── the scan accumulates rows across a whole pass and flushes one POST per
# (tick, namespace) after the stacks loop, so a harness running one extracted block has no
# flush to assert on. Shim it to capture calls instead.
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$REPLAY_ACTIONS"   # $5 = the ADR-125 lane base, passed explicitly by the queued clause ($qbase)
}

# ADR-125: `item_class_push` rows carry the item's LANE base. The queued clause passes its own
# `$qbase` (the issue's `Base:` line, defaulted to the repo default branch — the same value the
# homelab#849 per-base cap reads); this bridge replays a default-branch issue.
qbase="${qbase:-master}"
