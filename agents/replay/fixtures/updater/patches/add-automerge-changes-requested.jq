# automerge-changes-requested-no-update (homelab#1896, PR#2303 review): ONE armed+BEHIND PR
# carrying the `automerge` label with reviewDecision CHANGES_REQUESTED. The label arm must NOT
# admit it: `reviewDecision == ""` is the no-approval signal, and CHANGES_REQUESTED is the
# opposite — the PR has an outstanding fix round, so it is not merge-ready and its branch must not
# be moved (the file header: "a changes-requested PR gets its fix round pushed BEHIND"). This is
# the row the label-only arm missed: the park guard excludes only REVIEW_REQUIRED, so without the
# `reviewDecision == ""` test an `automerge` PR at CHANGES_REQUESTED — on any repo, including
# approval-required ones — read merge-ready. Held (noop).
. + [
  { number: 163, createdAt: "2026-09-16T12:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-16T12:01:00Z" }, reviewDecision: "CHANGES_REQUESTED",
    baseRefName: "master", labels: [ { name: "automerge" } ], headRefOid: "cr163oid456" }
]