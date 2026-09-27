# add-renovate-behind (ADR-141 (minted in homelab PR#2003 — GitHub Actions majors merge on their own; this carve-out is one of its consequences)): the add-behind shape — armed+BEHIND, APPROVED (the reviewer's lens
# verdict on a GitHub Actions major) — but Renovate-authored. Whether the nudge fires is the row's
# rows/<id>/gh/pr-view-150.json overlay's call: every commit Renovate's → Renovate rebases it
# itself (no PUT); a worker commit on the branch → Renovate has let go, nudge as usual.
. + [
  {
    "number": 150,
    "mergeStateStatus": "BEHIND",
    "autoMergeRequest": { "enabledAt": "2026-09-27T06:01:00Z" },
    "reviewDecision": "APPROVED",
    "headRefOid": "ren150oid789",
    "author": { "login": "app/homelab-renovate-1234" },
    "headRefName": "renovate/github-actions"
  }
]
