# ── bridge ── the test setup for the reviewable_again predicate in the changes-requested clause.
# The bridge prepares:
# - IN_SLUG: the test repo
# - IN_REPO: repo name
# - The gh pr view mock returns a PR object with reviews, commits, and updatedAt timestamps.
#
# The rows themselves patch the test data to vary the input axis:
# - no-content-after-review: newest_commit_at > newest_review_at
# - body-only-after-review: updatedAt > newest_review_at AND updatedAt > newest_commit_at
# - nothing-after-review: both conditions false
#
IN_SLUG="teststuffstash/homelab"
IN_REPO="homelab"
IN_U="2168"
