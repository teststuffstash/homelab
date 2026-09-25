# merge-commit-not-content: an UPDATER merge commit lands after the approval. Merge commits bring
# no PR-authored diff (oracle-fleet#57, the nine-review loop) — the reflex's newest_commit_at
# excludes them and so must this copy: the handoff still proceeds.
.commits += [{
  "oid": "0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d",
  "messageHeadline": "Merge branch 'master' into renovate/actions-checkout-7.x",
  "committedDate": "2026-09-25T13:00:00Z"
}]
