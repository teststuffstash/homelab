# annotations-replay — the failing check's annotation names a path under the declared Touches
# (`agents/replay/fixtures/goal`) that is ALSO an ADR-097 replay-exempt class (`agents/replay/**`).
# `fp_conflict` strips exempt entries from BOTH lists, so the annotation became an empty list, the
# belt read "outside footprint" and HELD a red that is inside it — replay reds are the usual ci
# reds in this lane. The strict predicate must escalate (reviewer finding 2, round 2).
.[0].path = "agents/replay/fixtures/goal/rows.psv"
