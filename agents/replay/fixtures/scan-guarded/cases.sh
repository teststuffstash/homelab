# ── the queued unit ── one row = one unit. The case rides the row's `env:` (CASE_REPO, CASE_NUM,
# CASE_TOUCHES, CASE_TITLE) so the table's rows ARE the decision table and this bridge stays fixed.
# `qtouches` carries the value the scan has ALREADY normalized (a missing `Touches:` line has
# become the `*` sentinel by this point, ADR-097), so the sentinel row is written as `*`.
CASES="${CASE_REPO}|${CASE_NUM}|${CASE_TOUCHES}|${CASE_TITLE}"
while IFS='|' read -r repo qnum qtouches qtitle; do
  [ -n "$qnum" ] || continue