# add-parked-behind: one armed+BEHIND CODEOWNER PARK #102 — bot-approved at head, reviewDecision
# still REVIEW_REQUIRED (the require_code_owner_review signature: a bot approval never satisfies
# it). The nudge must NOT touch it (#1649): the park is leg 1's to leave BEHIND, and nudging it
# costs one `ci` run per master push for the whole park — the churn #1452 exists to end, measured
# on PR#1576 ×87 / PR#1540 ×92 / PR#1541 ×50 before this row existed.
. + [
  {
    "number": 102,
    "mergeStateStatus": "BEHIND",
    "autoMergeRequest": { "enabledAt": "2026-09-08T20:01:00Z" },
    "reviewDecision": "REVIEW_REQUIRED",
    "headRefOid": "park102oid789",
    "latestReviews": [
      { "author": { "login": "homelab-reviewer[bot]" }, "state": "APPROVED",
        "submittedAt": "2026-09-08T23:06:57Z" }
    ],
    "reviews": [
      { "author": { "login": "homelab-reviewer[bot]" }, "state": "APPROVED",
        "submittedAt": "2026-09-08T23:06:57Z" }
    ]
  }
]