# ── observation point ── verify that pagination was handled correctly.
# The test verifies that PF_NEWEST_VERDICT correctly picks the GLOBALLY newest review,
# not just the newest on a single page.

if [ -z "${PF_NEWEST_VERDICT:-}" ] || [ "$PF_NEWEST_VERDICT" = "null" ]; then
  echo "→ FAILED: PF_NEWEST_VERDICT is empty or null (expected it to be set)"
  exit 1
fi

# Extract the reviewer login and timestamp from PF_NEWEST_VERDICT
# Should be: {"state":"CHANGES_REQUESTED","user":{"login":"reviewer3"},"submitted_at":"2026-09-08T12:00:00Z"}
PF_VD_USER="$(printf '%s' "$PF_NEWEST_VERDICT" | jq -r '.user // "unknown"' 2>/dev/null || echo "unknown")"
PF_VD_TIME="$(printf '%s' "$PF_NEWEST_VERDICT" | jq -r '.submitted_at // "unknown"' 2>/dev/null || echo "unknown")"

if [ "$PF_VD_TIME" = "2026-09-08T12:00:00Z" ]; then
  echo "→ VERIFIED: PF_NEWEST_VERDICT picked the globally newest review (2026-09-08T12:00:00Z)"
else
  echo "→ FAILED: PF_NEWEST_VERDICT has wrong timestamp: $PF_VD_TIME (expected 2026-09-08T12:00:00Z)"
  exit 1
fi

# Verify reviews.md lists them in newest-first order
if [ -n "${PF_REVIEWS_MD:-}" ]; then
  # Check that reviewer3 (newest) appears before reviewer2 and reviewer1
  REVIEWER3_POS="$(printf '%s' "$PF_REVIEWS_MD" | grep -n "reviewer3" | head -1 | cut -d: -f1)"
  REVIEWER2_POS="$(printf '%s' "$PF_REVIEWS_MD" | grep -n "reviewer2" | head -1 | cut -d: -f1)"

  if [ -n "$REVIEWER3_POS" ] && [ -n "$REVIEWER2_POS" ]; then
    if [ "$REVIEWER3_POS" -lt "$REVIEWER2_POS" ]; then
      echo "→ VERIFIED: reviews.md lists reviewer3 before reviewer2 (correct newest-first order)"
    else
      echo "→ FAILED: reviews.md lists reviewer2 before reviewer3 (expected newest-first order)"
      exit 1
    fi
  fi
fi

echo "REACHED: end"
