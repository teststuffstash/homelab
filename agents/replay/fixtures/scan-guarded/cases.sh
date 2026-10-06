# ── the queued unit ── one row = one unit. The case rides the row's `env:` (CASE_REPO, CASE_NUM,
# CASE_TOUCHES, CASE_TITLE) so the table's rows ARE the decision table and this bridge stays fixed.
# `qtouches` carries the value the scan has ALREADY normalized (a missing `Touches:` line has
# become the `*` sentinel by this point, ADR-097), so the sentinel row is written as `*`.
# A footprint the env column cannot carry (it is space-split) rides a row overlay instead: a
# `case-touches.txt` in rows/<id>/ lands in the world and wins over CASE_TOUCHES — the annotated
# row needs `path (comment)` with its space intact, which is the whole point of that row.
if [ -f "$REPLAY_WORLD/case-touches.txt" ]; then CASE_TOUCHES="$(cat "$REPLAY_WORLD/case-touches.txt")"; fi
CASES="${CASE_REPO}|${CASE_NUM}|${CASE_TOUCHES}|${CASE_TITLE}"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue