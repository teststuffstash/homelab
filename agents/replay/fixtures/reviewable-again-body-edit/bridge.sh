# ── bridge ── prepare test data with three scenarios for reviewable_again predicate.
# Scenario 1: new commits after the last review (existing case, no regression)
# Scenario 2: PR body edited after the last review, no new commits (the fix)
# Scenario 3: no commits or body edits after the last review (existing case, not reviewable)

test_scenarios="
---
## Scenario 1: new commit after review
newest_review_at: 2026-10-02T12:00:00Z
newest_commit_at: 2026-10-03T13:00:00Z
updatedAt: 2026-10-02T12:00:00Z
expected: held (new commit is newer than review)

---
## Scenario 2: body edit after review, no new commits
newest_review_at: 2026-10-02T12:00:00Z
newest_commit_at: 2026-10-01T10:00:00Z
updatedAt: 2026-10-03T14:00:00Z
expected: held (body was updated after review)

---
## Scenario 3: nothing new after review
newest_review_at: 2026-10-02T12:00:00Z
newest_commit_at: 2026-10-01T09:00:00Z
updatedAt: 2026-10-02T11:00:00Z
expected: not-held (neither commits nor body edits after review)
"
