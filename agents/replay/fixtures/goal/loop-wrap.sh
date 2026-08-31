# ── loop wrapper ── the goal-decompose block uses `continue` to skip the queued-classification
# block that follows it in the scan's per-queued-issue loop. In the fixture there is no enclosing
# loop, so we provide one. The `continue` skips to the `done` below, which is before the goal-lane
# block — correct: a refused or decomposed goal does not re-enter the goal lane in the same tick.
for _ in 1; do