# post-#1452: #101 carries a bot approval that post-dates its newest non-merge commit, because
# leg 1 now picks MERGE-READY PRs only. Without it this row would assert nothing about the 422
# branch (the pick would be empty and the PUT never made).
# update-fail: one armed+BEHIND PR #101 — the PUT fails (422), triggering the label branch
. + [
  { number: 101, createdAt: "2026-08-19T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T09:01:00Z" }, reviewDecision: "", baseRefName: "master", labels: [],
    headRefOid: "abc123def456",
    commits: [ { messageHeadline: "fix: the thing", committedDate: "2026-08-19T09:00:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
                 submittedAt: "2026-08-19T09:30:00Z" } ] }
]