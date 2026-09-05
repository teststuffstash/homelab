# unreviewed-behind-no-update (#1452) + merge-ready-only-off-legacy-pick: two armed+BEHIND
# candidates that NOBODY has reviewed. Under the #1452 merge-ready predicate neither is picked
# (expect `noop`) — THIS ROW IS THE PIN for the behaviour change and reds on base, where the older
# #101 was updated. With UPDATER_MERGE_READY_ONLY=0 the pre-#1452 pick returns and #101 wins the
# FIFO again. The merge-ready twin of this world (same two PRs, bot-approved) is
# patches/add-two-behind-ready.jq, which keeps the `fifo-pick` row's assertion intact.
. + [
  { number: 101, createdAt: "2026-08-19T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T09:01:00Z" }, reviewDecision: "", baseRefName: "master", labels: [],
    headRefOid: "abc123def456" },
  { number: 102, createdAt: "2026-08-19T10:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T10:01:00Z" }, reviewDecision: "", baseRefName: "master", labels: [],
    headRefOid: "789012ghi345" }
]
