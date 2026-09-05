# add-member-queued — the same tree member (#301) under open goal #29, but carrying the
# `agent/queued` LIFECYCLE label. ADR-122 (4): a lifecycle label means an authoring moment or a
# human already released the member, so it reads as ADOPTED-open without a store row — which is
# what keeps every pre-S8 goal counting correctly with no backfill. The row that uses this patch
# also overlays an issue-list.json carrying #301 OPEN + labelled, since the completion predicate
# reads the CONTAINER's descendant set (kidsall), never `openall`.
. + [
  {
    "number": 301,
    "title": "tree member — released by a human",
    "labels": [ { "name": "agent-fix" }, { "name": "agent/queued" } ],
    "body": "Touches: src/thing.py\n",
    "parent": { "number": 29 }
  }
]
