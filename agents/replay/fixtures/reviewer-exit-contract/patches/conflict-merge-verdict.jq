# conflict-merge-verdict — overlay the conflict-resolution-merge commit shape + a LIVE verdict
# submitted AFTER the content commit (20:26:16Z) but BEFORE the merge commit (20:32:37Z). The
# at-head filter is `submittedAt >= newest_commit`; newest_commit must resolve to the CONTENT
# commit's date, not the merge's — otherwise this verdict fails `>= merge-date` and the run
# false-reds FINAL=10 for a review that genuinely landed on the content. The old filter
# (startswith("Merge branch ") only) left the merge un-skipped and hit exactly that false red.
.commits = [
  {"oid": "de24929b003e7e860f9291c95ebbfa2f79225b2a", "messageHeadline": "Merge remote-tracking branch 'origin/master' into fix/issue-560-reviewer-exit-contract", "committedDate": "2026-08-18T20:32:37Z"},
  {"oid": "34eee3e0c048cbe8b268a28d3efb9131a4547749", "messageHeadline": "reviewer-session: exit contract — a session with no verdict, no aside, and no breaker must not report Succeeded", "committedDate": "2026-08-18T20:26:16Z"}
] |
.reviews = [{author: {login: "homelab-reviewer"}, state: "APPROVED", submittedAt: "2026-08-18T20:30:00Z"}]
