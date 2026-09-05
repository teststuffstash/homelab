# ── bridge ── the per-repo loop state the review-pick block reads. Every name here is a REFLEX
# variable the enclosing `for repo in $REPOS` loop sets (`prs`, `REVIEWER_LOGIN`,
# `DEFAULT_BRANCH`), never a harness invention — a bridge that renames things pins a different
# clause.
#
# `prs` is the `gh pr list` payload the reflex already holds by the time the block runs, so it
# arrives as a recorded world file rather than a stubbed call: the block under test is the jq
# PREDICATE, not the listing.
prs="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
REVIEWER_LOGIN="homelab-reviewer"
DEFAULT_BRANCH="master"
