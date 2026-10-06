# automerge-approval-required-no-update (homelab#1896): ONE armed+BEHIND PR carrying the
# `automerge` label on a repo whose ruleset REQUIRES approval (reviewDecision REVIEW_REQUIRED, no
# bot approval yet). The label arm must NOT bypass the approval gate: the park guard (#1649) holds
# it. On approval-required repos the same automerge class is covered by renovate-approve →
# APPROVED → arm 1; until then it is not merge-ready.
. + [
  { number: 162, createdAt: "2026-09-16T11:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-16T11:01:00Z" }, reviewDecision: "REVIEW_REQUIRED",
    baseRefName: "master", labels: [ { name: "automerge" } ], headRefOid: "req162oid123" }
]