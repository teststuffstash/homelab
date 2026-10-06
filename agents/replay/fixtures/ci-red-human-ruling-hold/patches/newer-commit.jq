# released row — new work landed AFTER the human's removal, so the hold self-releases.
# The base world's only commit (2026-09-08T17:00:00Z) predates the removal (18:08:41Z); this
# patch adds a commit at 19:30:00Z, newer than the removal, which re-arms MP-T13.
.commits += [{
  "oid": "aaaaaaaabbbbccccddddeeeeffff000011112222",
  "committedDate": "2026-09-08T19:30:00Z"
}]