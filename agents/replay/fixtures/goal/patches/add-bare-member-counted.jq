# add-bare-member-counted — ONE bare, undispositioned tree member (#301) under open goal #29,
# machine-classifiable footprint and no `agent-fix` / `agent/queued`: exactly the shape the
# RETIRED walk queued (PR#1242 → #1249). The row that uses this patch also overlays an
# issue-list.json carrying #301 as an OPEN descendant, so the member is in the CONTAINER's
# descendant set, not just in `openall`.
#
# That pairing is what keeps the ADR-122 pin from being a pure-absence contract
# (workflow.md §"What the pin-vacuity gate proves"): the member still moves a POSITIVE line —
# the goal's burn-down goes 1 open / 2 closed of 3 → 2 open / 2 closed of 4 and the store is
# PATCHed — while producing no queue write. Counted by the container, queued by nobody.
. + [
  {
    "number": 301,
    "title": "bare tree member — machine-doable path",
    "labels": [],
    "body": "Touches: src/thing.py\n",
    "parent": { "number": 29 }
  }
]
