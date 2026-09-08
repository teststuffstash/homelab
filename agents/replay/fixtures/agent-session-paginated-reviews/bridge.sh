# ── bridge ── test environment for paginated reviews in agent-session.sh
#
# Sets up variables needed for the fetch-reviews block to run.
# The world files provide paginated (multi-page) review responses via gh api --paginate.
PF_SLUG="foo/bar"
PF_PR="1"
WORK_BRANCH="fix/test"

# Define PF_INDEX_ITEM function (used by the fetch-reviews block)
PF_INDEX=""
PF_INDEX_ITEM() { PF_INDEX="${PF_INDEX}${1}  ${2}${3:+  ${3}}"$'\n'; }
