# merge-remote-not-content (homelab#2181): a NON-updater merge lands after the approval — the
# seat brought the branch current with `git merge origin/master` (headline "Merge remote-tracking
# branch 'origin/master' into …"), NOT the updater's "Merge branch 'master' into …". The old
# one-prefix filter counted it as content, so the newest content commit became the merge's date and
# the 12:00Z approval read as stale — the permanent refusal on #2046. A merge brings no PR-authored
# diff, so the handoff must still proceed.
.commits += [{
  "oid": "1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4",
  "messageHeadline": "Merge remote-tracking branch 'gh/master' into renovate/helm-3.x",
  "committedDate": "2026-09-25T13:00:00Z"
}]
