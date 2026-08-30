# race-422: one armed+BEHIND PR #101 with a headRefOid — the PUT fails (422, expected_head_sha
# mismatch simulating a concurrent push), and the script skips without labeling (homelab#986).
. + [
  { number: 101, createdAt: "2026-08-19T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T09:01:00Z" }, reviewDecision: "", labels: [],
    headRefOid: "abc123def456" }
]