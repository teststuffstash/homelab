# post-#1452: both PRs are MERGE-READY (see add-two-lanes.jq) — the subject here is the
# within-lane serializer, not the merge-ready predicate.
# same-lane-one-update (ADR-125 (2), homelab#1422): TWO armed+BEHIND PRs sharing ONE non-default
# lane. Within a lane the serializer is unchanged — exactly one update per pass, oldest first —
# and the lane it holds is a `goal/**` base, so a naive implementation that special-cased only the
# default branch reds here. (The default lane's own within-lane FIFO is the `fifo-pick` row; a
# second master row would repeat that assertion instead of earning a delta.)
# EXPECTATION: ONE update-branch call, on the OLDER #110 (09:00 < 10:00); #111 waits for the next
# pass exactly as #102 does in `fifo-pick`.
. + [
  { number: 110, createdAt: "2026-08-19T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T09:01:00Z" }, reviewDecision: "",
    baseRefName: "goal/x", labels: [], headRefOid: "goal110oid789",
    commits: [ { messageHeadline: "feat: goal one", committedDate: "2026-08-19T09:00:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
                 submittedAt: "2026-08-19T09:30:00Z" } ] },
  { number: 111, createdAt: "2026-08-19T10:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T10:01:00Z" }, reviewDecision: "",
    baseRefName: "goal/x", labels: [], headRefOid: "goal111oid012",
    commits: [ { messageHeadline: "feat: goal two", committedDate: "2026-08-19T10:00:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
                 submittedAt: "2026-08-19T10:30:00Z" } ] }
]
