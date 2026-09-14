# park-skip: one codeowner-parked PR — bot-approved at head ∧ REVIEW_REQUIRED ∧ armed+BEHIND.
# The main pick must SKIP this (noop). The parked condition is that the bot has given an APPROVED
# review but reviewDecision is still REVIEW_REQUIRED (a human codeowner must also approve).
# This row pins the PRE-FILTER's cost path (its `latestReviews` arm sees the bot APPROVED, so the
# PR never even becomes a candidate). The ENFORCEMENT — a park rejected on `reviewDecision` alone,
# whatever `latestReviews` says — is pinned by `parked-head-approved-no-update` (#1649).
. + [
  { number: 130, createdAt: "2026-09-03T12:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-03T12:01:00Z" }, reviewDecision: "REVIEW_REQUIRED", baseRefName: "master",
    labels: [],
    headRefOid: "park130oid789",
    latestReviews: [
      { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED",
        submittedAt: "2026-09-03T12:30:00Z" }
    ] }
]