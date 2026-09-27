# ADR-141 rows: ONE Renovate-authored armed+BEHIND PR with reviewDecision APPROVED (the reviewer's
# lens verdict on a GitHub Actions major — merge-ready on the snapshot alone). Whether the updater
# touches it is the row's pr-view-150 overlay's call: all commits Renovate's → Renovate rebases it
# itself (skip); a worker commit on the branch → Renovate has stopped maintaining it (update).
. + [
  { number: 150, createdAt: "2026-09-27T06:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-27T06:01:00Z" }, reviewDecision: "APPROVED", baseRefName: "master", labels: [],
    headRefOid: "ren150oid789", author: { login: "homelab-renovate-1234[bot]" },
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED", submittedAt: "2026-09-27T06:30:00Z" } ] }
]
