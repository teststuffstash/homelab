# add-c-members — the (c) HOLD's world (homelab#2565): ONE undispositioned tree member (#301) and
# ONE adopted-open member (#302, `agent/queued`, no store row).
#
# WHY TWO MEMBERS. #302 is what keeps trigger (b) SILENT — it counts toward the completion
# predicate (`gopen_n_ckpt` = 1) — so the row isolates (c): the only reason a unit can appear is
# the undispositioned set. Without it (b) fires on the same tick and the row would pin (b)'s
# stream, not (c)'s. #302 carries a lifecycle label, so the homelab#2052 ⏸ adopted-open-unlabelled
# line stays out of the stream and the row is about (c) alone.
#
# The row that uses this patch also overlays an issue-list.json carrying #301/#302 as OPEN
# descendants, so both are in the CONTAINER's descendant set, not just in `openall`.
. + [
  {
    "number": 301,
    "title": "bare tree member — machine-doable path",
    "labels": [],
    "body": "Touches: src/thing.py\n",
    "parent": { "number": 29 }
  },
  {
    "number": 302,
    "title": "adopted member — already released",
    "labels": [ { "name": "agent/queued" } ],
    "body": "Touches: src/other.py\n",
    "parent": { "number": 29 }
  }
]
