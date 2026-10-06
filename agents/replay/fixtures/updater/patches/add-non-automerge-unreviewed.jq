# non-automerge-unreviewed-no-update (homelab#1896): ONE armed+BEHIND PR on a no-approval repo
# (reviewDecision "") with NO `automerge` label and NO bot approval — an ordinary PR waiting for
# its first review. The updater must HOLD it (the #1452 waste: updating before review). The
# negative control for the label arm: the label is load-bearing, not "any PR on a no-approval repo".
. + [
  { number: 161, createdAt: "2026-09-16T10:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-16T10:01:00Z" }, reviewDecision: "", baseRefName: "master",
    labels: [], headRefOid: "plain161oid456" }
]