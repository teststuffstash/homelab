# update-branch-repoint — GitHub re-points a review's commit_id to the merge commit
# created by update-branch. The review was submitted before the merge commit existed
# (review submitted at 2026-09-04T17:15:45Z, but the merge commit's committer_date is
# 2026-09-05T07:37:55Z). This is the signature of a healthy update-branch re-point and
# must NOT be flagged as anomalous. The merge commit is 2-parent.
.commits = [
  {"oid": "abc1234abc1234abc1234abc1234abc1234abc1", "messageHeadline": "Merge branch 'master' into fix/test-pr", "committedDate": "2026-09-05T07:37:55Z"},
  {"oid": "abc1234def567890abcdef", "messageHeadline": "fix: the thing", "committedDate": "2026-08-18T17:50:00Z"}
] |
.reviews = [{author: {login: "homelab-reviewer"}, state: "APPROVED", submittedAt: "2026-09-04T17:15:45Z"}]
