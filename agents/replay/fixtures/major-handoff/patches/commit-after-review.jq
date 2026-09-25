# approval-stale: a CONTENT commit lands after the 12:00Z approval — a fix-round push. The verdict
# is no longer at head (review-reflex.sh newest_commit_at / bot_approved_head, replicated in
# agents/major-handoff.sh).
.commits += [{
  "oid": "f00dbabe0c1d2e3f4a5b6c7d8e9f0a1b2c3d4e5f",
  "messageHeadline": "fix: helm plugin install --verify=false (reviewer round 2)",
  "committedDate": "2026-09-25T13:00:00Z"
}]
