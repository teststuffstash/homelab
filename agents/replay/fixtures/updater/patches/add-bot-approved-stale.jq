# stale-approval-no-update (#1452): armed+BEHIND, the reviewer bot HAS approved — but a CONTENT
# commit landed after the verdict, so the approval is stale and the PR is NOT merge-ready (GitHub
# would dismiss it on that push anyway). The re-review is the reflex's job and runs BEHIND
# (PR#1446); the updater must spend no CI on it. Expect: noop.
. + [
  { number: 142, createdAt: "2026-09-05T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-05T09:01:00Z" }, reviewDecision: "", baseRefName: "master", labels: [],
    headRefOid: "stale142oid456",
    commits: [ { messageHeadline: "feat: content", committedDate: "2026-09-05T09:10:00Z" },
               { messageHeadline: "fix: review round", committedDate: "2026-09-05T10:00:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
                 submittedAt: "2026-09-05T09:30:00Z" } ] }
]
