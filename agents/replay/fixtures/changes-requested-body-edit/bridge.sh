#!/usr/bin/env bash
# bridge.sh — test the reviewable_again predicate with different edit patterns.
# Tests that the jq definitions from review-reflex.sh correctly identify when
# a PR is reviewable again based on body edits after a CHANGES_REQUESTED review.

set -euo pipefail

# Extract the jq block from review-reflex.sh using the sentinel markers.
# This ensures the fixture pins the ACTUAL predicate, not a hardcoded stub —
# on the base tree (pre-fix), the extraction gets the old predicate without lastEditedAt,
# so the test will RED (pin-vacuity gate).
JQ_DEFS="$(sed -n '/# >>>REPLAY:reviewable_again>>>/,/# <<<REPLAY:reviewable_again<<</p' "${REPLAY_ROOT:?REPLAY_ROOT unset — the replay harness exports it}/agents/review-reflex.sh")"
if [ -z "$(printf '%s' "$JQ_DEFS" | tr -d '[:space:]')" ]; then
  echo "bridge: EMPTY reviewable_again extraction from ${REPLAY_ROOT}/agents/review-reflex.sh — sentinel block missing or moved" >&2
  exit 1
fi

# THE FETCH ROWS (TEST_CASE=fetch): lastEditedAt is NOT in the listed PR (gh has no such field —
# the 2026-10-06 abort); it arrives ONLY through the fake `gh api graphql` (world gh/api-graphql.json)
# read by the ONE home, agents/pr-last-edited.sh, via the reflex's REAL merge block (extracted by
# sentinel, like the predicate). So these rows pin the FETCH + the by-number merge, not just the jq.
if [ "${TEST_CASE:-}" = fetch ]; then
  . "${REPLAY_ROOT}/agents/pr-last-edited.sh"
  MERGE_BLOCK="$(sed -n '/# >>>REPLAY:last-edited-merge>>>/,/# <<<REPLAY:last-edited-merge<<</p' "${REPLAY_ROOT}/agents/review-reflex.sh")"
  if [ -z "$(printf '%s' "$MERGE_BLOCK" | tr -d '[:space:]')" ]; then
    echo "bridge: EMPTY last-edited-merge extraction from ${REPLAY_ROOT}/agents/review-reflex.sh — sentinel block missing or moved" >&2
    exit 1
  fi
  slug="teststuffstash/oracle-fleet"
  prs="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
  eval "$MERGE_BLOCK"
  # Every listed PR runs the predicate: the non-CR #816 must stay false and must not have been
  # queried (the query asks for CHANGES_REQUESTED numbers only — the budget rule).
  printf '%s' "$prs" | jq -r "$JQ_DEFS
    .[] | \"#\(.number) reviewable_again=\(if reviewable_again then \"true\" else \"false\" end)\""
  exit 0
fi

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
