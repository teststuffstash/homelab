#!/usr/bin/env bash
# bridge.sh — test the reviewable_again predicate with different edit patterns.
# Tests that the jq definitions from review-reflex.sh correctly identify when
# a PR is reviewable again based on body edits after a CHANGES_REQUESTED review.

set -euo pipefail

# The jq block extracted from review-reflex.sh defines:
# - newest_review_at: the max submittedAt from APPROVED or CHANGES_REQUESTED reviews
# - newest_commit_at: the max committedDate from non-merge commits
# - reviewable_again: true if CHANGES_REQUESTED AND (newest_commit > newest_review OR lastEditedAt > newest_review)
JQ_DEFS='
  def is_merge:
    (.messageHeadline // "") | (startswith("Merge branch ") or startswith("Merge remote-tracking branch ") or startswith("Merge pull request "));
  def newest_review_at:
    ([ .reviews[]? | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED") | .submittedAt ] | max) // "";
  def newest_commit_at:
    ([ .commits[]? | select(is_merge | not) | .committedDate ] | max) // "";
  def reviewable_again:
    (.reviewDecision == "CHANGES_REQUESTED") and
    ((newest_commit_at > newest_review_at) or (((.lastEditedAt // "") > newest_review_at)));
'

# Test data based on ${TEST_CASE} environment variable
case "${TEST_CASE:-body-edit-only}" in
  body-edit-only)
    # Body edited after CHANGES_REQUESTED; no new commits
    # lastEditedAt (10:30) > newest_review_at (10:00) → reviewable
    TEST_INPUT='{
      "reviewDecision": "CHANGES_REQUESTED",
      "reviews": [
        {
          "state": "CHANGES_REQUESTED",
          "submittedAt": "2026-01-01T10:00:00Z"
        }
      ],
      "commits": [
        {
          "committedDate": "2026-01-01T09:00:00Z",
          "messageHeadline": "Fix the thing"
        }
      ],
      "lastEditedAt": "2026-01-01T10:30:00Z"
    }'
    ;;
  control-no-changes)
    # Neither commits nor body edited after CHANGES_REQUESTED
    # newest_commit (09:00) < newest_review (10:00), lastEditedAt (09:30) < newest_review → not reviewable
    TEST_INPUT='{
      "reviewDecision": "CHANGES_REQUESTED",
      "reviews": [
        {
          "state": "CHANGES_REQUESTED",
          "submittedAt": "2026-01-01T10:00:00Z"
        }
      ],
      "commits": [
        {
          "committedDate": "2026-01-01T09:00:00Z",
          "messageHeadline": "Fix the thing"
        }
      ],
      "lastEditedAt": "2026-01-01T09:30:00Z"
    }'
    ;;
esac

# Run the test
RESULT="$(printf '%s' "$TEST_INPUT" | jq -r "$JQ_DEFS
  (if reviewable_again then \"true\" else \"false\" end)")"

printf 'reviewable_again=%s\n' "$RESULT"
