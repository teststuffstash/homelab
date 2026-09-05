# ── bridge ── the scan state the guarded blocks read. Every name is a variable the shipped script
# sets before the queued loop (`HERE`, `orphans`), never a harness invention.
#
# `HERE` points at the real `agents/` in the checkout, which is what makes `PIN_ONLY_LINT` resolve
# to the real `scripts/pin-only-lint.sh` — the one definition of GUARDED. Nothing here declares a
# path: a fixture that named the guarded files itself would be the second copy the change exists to
# prevent, and would go green while the scan and the lint drifted apart.
HERE="$REPLAY_ROOT/agents"
# The scan's own source line, verbatim — `fp_norm_entry`/`fp_conflict` are the ADR-097 predicate
# and the guarded check must use the same path-boundary reasoning, not a private copy of it.
. "${HERE}/footprint.sh"
orphans=""

# ── stub ── item_class_push is defined in the item-class block; the guarded-hold block calls it
# but this fixture tests only the guarded-hold logic. Shim to capture calls instead.
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$REPLAY_ACTIONS"   # $5 = the ADR-125 lane base, passed explicitly by the queued clause ($qbase)
}

# ADR-125: `item_class_push` rows carry the item's LANE base. The queued clause passes its own
# `$qbase` (the issue's `Base:` line, defaulted to the repo default branch — the same value the
# homelab#849 per-base cap reads); this bridge replays a default-branch issue.
qbase="${qbase:-master}"
