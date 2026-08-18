# conflict-merge-aside — overlay the conflict-resolution-merge commit shape + a standing-aside
# comment keyed to the CONTENT sha. The merge ("Merge remote-tracking branch 'origin/master' into
# <branch>") is the NEWEST commit; the real content commit is older. The aside assert must find its
# terminal at the CONTENT sha (34eee3e0), not at the merge sha (de24929b) — the exact counterexample
# from the reviewer's CHANGES_REQUESTED on PR#571. Under the old filter (startswith("Merge branch ")
# only) newest_sha8 resolved to the merge sha and a legitimately-posted aside keyed head=<content>
# was invisible to the assert → false-red FINAL=10.
.commits = [
  {"oid": "de24929b003e7e860f9291c95ebbfa2f79225b2a", "messageHeadline": "Merge remote-tracking branch 'origin/master' into fix/issue-560-reviewer-exit-contract", "committedDate": "2026-08-18T20:32:37Z"},
  {"oid": "34eee3e0c048cbe8b268a28d3efb9131a4547749", "messageHeadline": "reviewer-session: exit contract — a session with no verdict, no aside, and no breaker must not report Succeeded", "committedDate": "2026-08-18T20:26:16Z"}
] |
.comments = [{author: {login: "homelab-reviewer"}, body: "STANDING ASIDE: checks-pending at 34eee3e0 — no verdict; the level-triggered review path re-dispatches when this settles. <!-- standing-aside head=34eee3e0 pre=checks-pending -->"}]
