#!/usr/bin/env bash
# test.sh — test the unified reviewable_again predicate with three scenarios.
# The predicate is now: (newest_commit_at > newest_review_at) OR
#                       (updatedAt > newest_review_at AND updatedAt > newest_commit_at)
set -euo pipefail

test_predicate() {
  local newest_review_at="$1" newest_commit_at="$2" updatedAt="$3"

  # Use jq for proper timestamp comparison
  jq -rn --arg nr "$newest_review_at" --arg nc "$newest_commit_at" --arg ua "$updatedAt" '
    if ($nc > $nr) or ($ua > $nr and $ua > $nc) then "held" else "not-held" end
  '
}

# Test scenario 1: new commit after review
result1="$(test_predicate "2026-10-02T12:00:00Z" "2026-10-03T13:00:00Z" "2026-10-02T12:00:00Z")"
[ "$result1" = "held" ] || { echo "FAIL: scenario 1 expected held, got $result1"; exit 1; }

# Test scenario 2: body edit after review, no new commits
result2="$(test_predicate "2026-10-02T12:00:00Z" "2026-10-01T10:00:00Z" "2026-10-03T14:00:00Z")"
[ "$result2" = "held" ] || { echo "FAIL: scenario 2 expected held, got $result2"; exit 1; }

# Test scenario 3: nothing new after review
result3="$(test_predicate "2026-10-02T12:00:00Z" "2026-10-01T09:00:00Z" "2026-10-02T11:00:00Z")"
[ "$result3" = "not-held" ] || { echo "FAIL: scenario 3 expected not-held, got $result3"; exit 1; }

echo "✓ All scenarios passed"
