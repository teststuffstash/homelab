# bot-approved-head-update (#1452): ONE armed+BEHIND PR whose reviewer-bot APPROVED post-dates the
# newest NON-MERGE commit, on a repo whose ruleset asks for no approval (reviewDecision ""). This
# is the merge-ready witness: nothing but currency + CI stands between it and auto-merge, so the
# updater brings it current. The trailing "Merge branch ..." commit is an EARLIER updater merge and
# is deliberately NEWER than the approval — merge commits are not content, so it must not un-ready
# the PR (the nine-review loop, oracle-fleet#57).
. + [
  { number: 141, createdAt: "2026-09-05T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-05T09:01:00Z" }, reviewDecision: "", baseRefName: "master", labels: [],
    headRefOid: "ready141oid123",
    commits: [ { messageHeadline: "feat: content", committedDate: "2026-09-05T09:10:00Z" },
               { messageHeadline: "Merge branch 'master' into fix/ready", committedDate: "2026-09-05T11:00:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
                 submittedAt: "2026-09-05T09:30:00Z" } ] }
]
