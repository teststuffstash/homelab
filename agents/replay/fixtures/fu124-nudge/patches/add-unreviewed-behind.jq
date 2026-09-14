# add-unreviewed-behind: one armed+BEHIND PR #103 with NO review requirement satisfied — the
# `reviewDecision: ""` shape of a repo whose ruleset asks for no approval (and the shape of a
# master-lane PR nobody has reviewed yet). The nudge must NOT touch it (#1649): it is not
# merge-ready, and the updater owns it — leg 1's `bot_approved_head` arm needs `reviews` plus a
# per-candidate commits probe that this fetch does not carry, so the nudge takes only the half the
# snapshot can decide (`reviewDecision == APPROVED`) rather than duplicating the predicate.
. + [
  {
    "number": 103,
    "mergeStateStatus": "BEHIND",
    "autoMergeRequest": { "enabledAt": "2026-09-08T20:01:00Z" },
    "reviewDecision": "",
    "headRefOid": "unrev103oid456"
  }
]