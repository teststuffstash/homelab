# add-verdict — overlay a LIVE (non-DISMISSED, APPROVED) verdict from our identity submitted AFTER
# the newest non-merge commit's committedDate. The at-head filter is `submittedAt >= newest_commit`,
# and the newest commit is 2026-08-18T17:50:00Z — so this submittedAt must be ≥ that.
.reviews = [{author: {login: "homelab-reviewer"}, state: "APPROVED", submittedAt: "2026-08-18T18:00:00Z"}]
