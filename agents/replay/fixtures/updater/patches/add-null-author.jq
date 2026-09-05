# null-author-deleted-review: one park whose latestReviews includes a review from a deleted
# GitHub account (.author.login is null). The park-skip predicate must not crash on this
# (old | startswith("homelab-reviewer") crashes with exit 5 under set -euo pipefail).
# The null author is not a bot approval → the guard degrades correctly: no skip → the
# park is refreshed exactly as before (no behavioural regression on a null author, just
# no crash).
. + [
  { number: 133, createdAt: "2026-09-03T14:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-03T14:01:00Z" }, reviewDecision: "REVIEW_REQUIRED", baseRefName: "master",
    labels: [],
    headRefOid: "nullauth133oid",
    latestReviews: [
      { author: null, state: "APPROVED",
        submittedAt: "2026-09-03T14:30:00Z" }
    ],
    commits: [ { messageHeadline: "fix: content", committedDate: "2026-09-03T14:00:00Z" } ],
    reviews: [
      { author: null, state: "APPROVED",
        submittedAt: "2026-09-03T14:30:00Z" }
    ] }
]
