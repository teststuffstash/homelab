# ── bridge ── the per-repo loop variables the arbitrate gate and the ordinary-path belt read.
# Both readers run in one pass over the same `prsjson`: #240 is the GATE leg (unarmed, so the
# gate's selector takes it) and #241 is the BELT leg (armed + green, so the belt's selector takes
# it). One world, both readers — the round-trip the fixture exists to prove.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace).
item_class_push() { :; }