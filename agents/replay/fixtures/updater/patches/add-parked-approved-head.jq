# parked-head-approved-no-update (#1649): the park shape that LEAKED — armed ∧ BEHIND ∧
# reviewDecision REVIEW_REQUIRED (the codeowner gate is what holds it) with the reviewer bot's
# APPROVED post-dating the newest NON-MERGE commit, and the snapshot's `latestReviews` entry for
# the bot reading NON-APPROVED (the approve-then-aside sequence — the PR#235 trap the platform's
# other readers carry the `reviews[]`, never `latestReviews[]` lesson for).
#
# This is the row that pins the DEFECT, not just the contract: on the pre-#1649 source the
# candidate pre-filter admitted it (its `latestReviews` arm saw no bot APPROVED) and the
# merge-ready arm then re-admitted it from `reviews[]` — probe, then UPDATE, one per master push
# for the whole park. The park is now decided by `reviewDecision` alone, so the row expects NO
# probe and NO update. `park-skip` (the same park with `latestReviews` reading APPROVED) stays as
# the pre-filter's cost-path pin; this row is the arm's.
. + [
  { number: 150, createdAt: "2026-09-08T20:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-08T20:01:00Z" }, reviewDecision: "REVIEW_REQUIRED",
    baseRefName: "master", labels: [], headRefOid: "park150oid789",
    latestReviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "COMMENTED",
                       submittedAt: "2026-09-08T23:30:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "CHANGES_REQUESTED",
                 submittedAt: "2026-09-08T21:18:47Z" },
               { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
                 submittedAt: "2026-09-08T23:06:57Z" } ] }
]