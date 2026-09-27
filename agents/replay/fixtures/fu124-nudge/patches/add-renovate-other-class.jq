# ADR-141 (minted in homelab PR#2003 — GitHub Actions majors merge on their own; this carve-out is one of its consequences) scope pin (PR#2004 review): add-renovate-behind's shape on a NON-Actions branch
# (`renovate/boto3-1.x` — global `rebaseWhen: conflicted`, Renovate never rebases it for
# staleness) → the nudge is this PR's currency and must fire, no commits probe needed.
. + [
  {
    "number": 152,
    "mergeStateStatus": "BEHIND",
    "autoMergeRequest": { "enabledAt": "2026-09-27T06:01:00Z" },
    "reviewDecision": "APPROVED",
    "headRefOid": "ren152oid789",
    "author": { "login": "app/homelab-renovate-1234" },
    "headRefName": "renovate/boto3-1.x"
  }
]
