# Paginated reviews in agent-session.sh

Tests that PF_NEWEST_VERDICT and PF_REVIEWS_MD correctly flatten and globally sort reviews when `gh api --paginate` returns multiple pages.

## Fixture behavior

Provides two pages of reviews:
- **Page 1**: reviewer1 (10:00), reviewer2 (11:00)
- **Page 2**: reviewer3 (12:00 — newest), reviewer4 (09:00)

Verifies:
1. PF_NEWEST_VERDICT correctly identifies reviewer3's 12:00 review as the newest (not reviewer2's 11:00)
2. PF_REVIEWS_MD lists reviews in globally sorted newest-first order
