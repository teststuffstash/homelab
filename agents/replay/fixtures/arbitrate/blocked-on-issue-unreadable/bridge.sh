# ── bridge ── the per-repo loop variables the arbitrate clause reads and writes.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
item_class_push() { :; }

# Simulate transient failure when reading blocker issue #489 using the framework's failure injection.
# The blocked-on-check function calls `gh issue view 489 --repo ...` and gets a read error,
# which should now be treated as blocked (fail-closed) rather than clear (fail-open).
# The slug for "issue view 489" is "issue-view-489", which becomes STUB_GH_issue_view_489 as an env var.
export STUB_GH_issue_view_489=fail
