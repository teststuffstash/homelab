# inherited-red rows (homelab#2588, the #2582 world): ONE armed+BEHIND PR at REVIEW_REQUIRED with no
# bot approval — not merge-ready, so only the inherited-red leg can take it. Whether it is updated is
# the row's `run list` overlay's call (rows/<id>/gh/run-list-*.json): the PR's newest CI run vs the
# base's newest successful one.
. + [
  { number: 170, createdAt: "2026-11-20T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-11-20T09:01:00Z" }, reviewDecision: "REVIEW_REQUIRED", baseRefName: "master", labels: [],
    headRefOid: "red170oid789", headRefName: "fix/red170", latestReviews: [], reviews: [] }
]
