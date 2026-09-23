# ── drive ── one unit per leg, straight through the real fast path (the world is keyed by PR
# number, so each leg's condition is a different recorded PR rather than a different code path).
echo "REACHED: blocked-on: human, no engagement after the marker — the edge emits no unit"
fast_unit_dispatch "changes-requested|circles|pr-396"
printf 'RETURN %s\n' "$?"

echo "REACHED: a newer human comment cleared the marker — the hold releases"
fast_unit_dispatch "changes-requested|circles|pr-397"
printf 'RETURN %s\n' "$?"

echo "REACHED: negative control — no marker at all, the unit dispatches"
fast_unit_dispatch "changes-requested|circles|pr-398"
printf 'RETURN %s\n' "$?"

echo "REACHED: agent/blocked on the PR itself (the main path's selector exclusion) — held"
fast_unit_dispatch "changes-requested|circles|pr-399"
printf 'RETURN %s\n' "$?"

echo "REACHED: the linked source issue #19 is agent/blocked (the main path's BLOCKED-SOURCE hold) — held"
fast_unit_dispatch "changes-requested|circles|pr-400"
printf 'RETURN %s\n' "$?"

echo "REACHED: the linked issue #20 is CLOSED with a stale agent/blocked label — the main path reads OPEN issues, so this dispatches"
fast_unit_dispatch "changes-requested|circles|pr-401"
printf 'RETURN %s\n' "$?"

echo "REACHED: end"
