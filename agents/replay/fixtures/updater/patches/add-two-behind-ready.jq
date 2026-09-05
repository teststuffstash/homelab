# fifo-pick (post-#1452): two MERGE-READY armed+BEHIND candidates — #101 is OLDER and must win the
# FIFO pick. "Merge-ready" is the new leg-1 predicate: the reviewer bot's APPROVED post-dates the
# newest NON-MERGE commit (`bot_approved_head`, review-reflex.sh's definition). The un-approved
# twins of these two PRs are the `unreviewed-behind-no-update` row (patches/add-two-behind.jq),
# which is the same world minus the approvals and now expects NO update — that row is the pin for
# the #1452 behaviour change and REDs on base.
# NOTE the [bot] suffix on #102's reviewer login: REST says `homelab-reviewer[bot]`, GraphQL says
# `homelab-reviewer` (the known mismatch) — the predicate normalizes, so both spellings count.
. + [
  { number: 101, createdAt: "2026-08-19T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T09:01:00Z" }, reviewDecision: "", baseRefName: "master", labels: [],
    headRefOid: "abc123def456",
    commits: [ { messageHeadline: "fix: the thing", committedDate: "2026-08-19T09:00:00Z" },
               { messageHeadline: "Merge branch 'master' into fix/x", committedDate: "2026-08-19T12:00:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer" }, state: "APPROVED",
                 submittedAt: "2026-08-19T09:30:00Z" } ] },
  { number: 102, createdAt: "2026-08-19T10:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T10:01:00Z" }, reviewDecision: "", baseRefName: "master", labels: [],
    headRefOid: "789012ghi345",
    commits: [ { messageHeadline: "fix: the other thing", committedDate: "2026-08-19T10:00:00Z" } ],
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
                 submittedAt: "2026-08-19T10:30:00Z" } ] }
]
