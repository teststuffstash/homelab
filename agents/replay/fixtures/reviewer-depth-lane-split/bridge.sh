# Bridge for s6-child-1-depth-rule block extraction and testing.
# Sets up minimal pod variables and mocks gh for the block execution.
#
HERE="$REPLAY_FIXTURE"
PR_NUMBER="${PR_NUMBER:-42}"
REPO_SLUG="${REPO_SLUG:-teststuffstash/test-project}"
ISSUE="${ISSUE:-1}"
SPROUT_DEPTH="${SPROUT_DEPTH:-0}"
PR_BASE="${PR_BASE:-master}"
ISSUE_TITLE="${ISSUE_TITLE:-}"
ISSUE_BODY="${ISSUE_BODY:-}"
PROMPT="Initial prompt."
ISSUE_IS_HOTFIX=""

# Mock gh for issue body fetches
gh() {
  {
    printf 'CALL gh'
    for _a in "$@"; do
      printf ' %s' "$_a"
    done
    printf '\n'
  } >> "$REPLAY_ACTIONS" 2>&1 || true

  case "$1" in
    api)
      printf '{"body":"%s"}' "$ISSUE_BODY"
      return 0
      ;;
  esac
  return 1
}

export PROMPT ISSUE_IS_HOTFIX
