# homelab#1985 residual 5: a codeowner PARK (armed + BEHIND + REVIEW_REQUIRED, the bot's APPROVED in
# latestReviews) on a Renovate branch — leg 1's pre-filter drops it unprobed, so a merged-into park
# that went red waited for the human with Renovate already disowned. Leg 1b hands it back.
. + [
  { number: 154, createdAt: "2026-10-20T06:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-10-20T06:01:00Z" }, reviewDecision: "REVIEW_REQUIRED", baseRefName: "master", labels: [],
    headRefOid: "ren154oid789", author: { login: "app/homelab-renovate-1234" }, headRefName: "renovate/major-postgres",
    latestReviews: [ { author: { login: "homelab-reviewer" }, state: "APPROVED" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED", submittedAt: "2026-10-20T06:30:00Z" } ] }
]
