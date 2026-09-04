# ── bridge ── the `gh pr list` payload the scan holds by the time the count block runs.
prsjson='[
  {"number": 1, "baseRefName": "master", "autoMergeRequest": {"enabledAt": "x"}, "reviewDecision": "APPROVED",         "mergeStateStatus": "CLEAN"},
  {"number": 2, "baseRefName": "master", "autoMergeRequest": {"enabledAt": "x"}, "reviewDecision": "REVIEW_REQUIRED",  "mergeStateStatus": "BLOCKED"},
  {"number": 3, "baseRefName": "master", "autoMergeRequest": {"enabledAt": "x"}, "reviewDecision": "REVIEW_REQUIRED",  "mergeStateStatus": "BEHIND"},
  {"number": 4, "baseRefName": "goal/1-x", "autoMergeRequest": {"enabledAt": "x"}, "reviewDecision": "REVIEW_REQUIRED", "mergeStateStatus": "BEHIND"},
  {"number": 5, "baseRefName": "master", "autoMergeRequest": null,               "reviewDecision": "REVIEW_REQUIRED",  "mergeStateStatus": "BLOCKED"},
  {"number": 6, "baseRefName": "master", "autoMergeRequest": {"enabledAt": "x"}, "reviewDecision": "CHANGES_REQUESTED", "mergeStateStatus": "BLOCKED"}
]'
