# pr-approved — the head was approved as-is (approval 14:00 postdates the last non-merge push
# 13:00) and the red came AFTER the approval (14:10): a converged, approved PR is not
# re-escalated by a later, unrelated red.
.reviewDecision = "APPROVED"
| .reviews = [{ "state": "APPROVED", "submittedAt": "2026-09-12T14:00:00Z" }]
| .statusCheckRollup = [{ "name": "ci", "conclusion": "FAILURE", "completedAt": "2026-09-12T14:10:00Z" }]
