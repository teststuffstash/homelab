# add-behind: one armed+BEHIND MERGE-READY PR #101 — the nudge's subject since #1649.
# `reviewDecision: "APPROVED"` is what makes it merge-ready ("nothing but currency + CI left"):
# the nudge is the deterministic accelerator for a PR the merge queue would update anyway, so the
# row's PR must carry the state the selector now requires. Before #1649 the selector was armed ∧
# BEHIND alone and this field was absent — which is exactly how the loop came to nudge codeowner
# parks (see patches/add-parked-behind.jq).
. + [
  {
    "number": 101,
    "mergeStateStatus": "BEHIND",
    "autoMergeRequest": { "enabledAt": "2026-08-20T11:01:00Z" },
    "reviewDecision": "APPROVED",
    "headRefOid": "abc123def456"
  }
]