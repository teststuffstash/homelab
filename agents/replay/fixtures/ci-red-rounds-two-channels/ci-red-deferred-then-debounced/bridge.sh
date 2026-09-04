# ── bridge ── the ci-red clause's per-red-PR loop, one PR wide. `head8` is the short head sha the
# clause computed above the extracted block and quotes in its report line; the `for` is the scan's
# own loop, kept because the block `continue`s out of it — that `continue` (before the 2/repo/scan
# dispatch cap, so a debounced PR never spends a slot a live red PR could use) is half the point.
slug="$IN_SLUG"
repo="$IN_REPO"
head8="$IN_HEAD8"
orphans=""
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }
for u in "$IN_PR"; do