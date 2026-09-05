# silent-dedup-checks-pending — overlay a PR churned by no-op master merges where:
# - The content commit (0c2be42f) has an existing standing-aside at (content, checks-pending) from a
#   previous dispatch.
# - A master merge (2f4de531) is now the newest commit ("Merge branch 'master'").
# - Checks are QUEUED at the tip.
# - On this new dispatch, the LLM detects an idempotent aside at (0c2be42f, checks-pending)
#   and exits silently (no new comment posted).
# - The problem: exit-contract finds the old aside and returns "terminal OK", invisibly consuming
#   the dispatch.
# The fix: the LLM should emit a SILENT_DEDUP: marker when it silently exits due to idempotent
# dedup, making it countable.
.commits = [
  {"oid": "2f4de531abcdef0123456789abcdef", "messageHeadline": "Merge branch 'master'", "committedDate": "2026-09-05T12:00:18Z"},
  {"oid": "0c2be42f123456789abcdefabcdef12", "messageHeadline": "fix: the thing from round 2", "committedDate": "2026-09-05T11:31:15Z"}
] |
.comments = [{author: {login: "homelab-reviewer"}, body: "STANDING ASIDE: checks-pending at 0c2be42f — no verdict; the level-triggered review path re-dispatches when this settles. <!-- standing-aside head=0c2be42f pre=checks-pending -->"}] |
.statusCheckRollup = [{"name":"ci", "conclusion": null, "status": "QUEUED"}]
