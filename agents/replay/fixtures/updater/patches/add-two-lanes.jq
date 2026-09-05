# two-lanes-two-updates (ADR-125 (2), homelab#1422): one armed+BEHIND PR on the DEFAULT lane and
# one on a goal lane. Before the per-lane pick these two competed for the single per-repo slot and
# the goal PR waited a whole pass (or many) behind master traffic it can never invalidate — an
# update-branch merge into `master`-based #101 cannot stale a review on `goal/x`-based #110,
# because the dismiss-on-push rule only reaches PRs sharing a base.
# EXPECTATION: TWO update-branch calls in ONE pass, one per lane. Order is jq's group_by key order
# (ascending): "goal/x" < "master", so #110 is called first.
. + [
  { number: 101, createdAt: "2026-08-19T09:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T09:01:00Z" }, reviewDecision: "",
    baseRefName: "master", labels: [], headRefOid: "abc123def456" },
  { number: 110, createdAt: "2026-08-19T10:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-08-19T10:01:00Z" }, reviewDecision: "",
    baseRefName: "goal/x", labels: [], headRefOid: "goal110oid789" }
]
