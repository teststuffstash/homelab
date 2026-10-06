# merge-pr-not-content (homelab#2181): a GitHub-UI merge lands after the approval — headline
# "Merge pull request #N from …". The third GitHub default merge shape; the old one-prefix filter
# counted it as content and refused the handoff. A merge brings no PR-authored diff, so the handoff
# must still proceed.
.commits += [{
  "oid": "2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5",
  "messageHeadline": "Merge pull request #2046 from teststuffstash/renovate/helm-3.x",
  "committedDate": "2026-09-25T13:00:00Z"
}]
