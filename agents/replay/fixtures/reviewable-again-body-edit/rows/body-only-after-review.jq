# body-only-after-review: updatedAt > newest_review_at AND updatedAt > newest_commit_at
# The PR body was edited (updatedAt) after both the review and the most recent commit.
# Keep commit before review, but updatedAt after both.
.commits[0].committedDate = "2026-10-01T10:00:00Z" | .updatedAt = "2026-10-03T14:00:00Z"
