# ADR-141 (minted in homelab PR#2003 — GitHub Actions majors merge on their own; this carve-out is one of its consequences) scope pin (PR#2004 review): the add-renovate-approved shape — Renovate-authored,
# armed+BEHIND, APPROVED, untouched — but on a NON-Actions branch (`renovate/boto3-1.x`, the
# python runtime class, which inherits the global `rebaseWhen: conflicted`). Renovate never
# rebases it for staleness, so this updater IS its currency: it must be updated, not skipped.
. + [
  { number: 152, createdAt: "2026-09-27T06:00:00Z", mergeStateStatus: "BEHIND",
    autoMergeRequest: { enabledAt: "2026-09-27T06:01:00Z" }, reviewDecision: "APPROVED", baseRefName: "master", labels: [],
    headRefOid: "ren152oid789", author: { login: "homelab-renovate-1234[bot]" }, headRefName: "renovate/boto3-1.x",
    reviews: [ { author: { login: "homelab-reviewer[bot]" }, state: "APPROVED", submittedAt: "2026-09-27T06:30:00Z" } ] }
]
