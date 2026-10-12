# ── bridge ── the per-repo scan variables the FU-079 backstop block reads (shared by the family rows)
slug="$IN_SLUG"
repo="$IN_REPO"
ISSUE_LIST_LIMIT=100
orphans=""
# the arming-grace clock: pinned so a row's "opened N hours ago" is deterministic
bk_now() { date -u -d "${IN_NOW:-2026-10-12T12:00:00Z}" +%s; }
