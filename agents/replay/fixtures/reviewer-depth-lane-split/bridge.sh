# Bridge for s6-child-1-depth-rule block extraction and testing.
# Sets up minimal pod variables and mocks gh for the block execution.
#
# `HERE` is what the reviewer's `rv_ib_get` resolves agents/issue_body.py against, so it must be
# the REAL agents/ directory: the hotfix probe below runs the actual parser on the actual body,
# never a restatement of it (a stub here would test the stub — jail-subagent-card §Tests).
HERE="$(cd "$REPLAY_FIXTURE/../../../.." && pwd)/agents"
PR_NUMBER="${PR_NUMBER:-42}"
REPO_SLUG="${REPO_SLUG:-teststuffstash/test-project}"
ISSUE="${ISSUE:-1}"
SPROUT_DEPTH="${SPROUT_DEPTH:-0}"
PR_BASE="${PR_BASE:-master}"
ISSUE_TITLE="${ISSUE_TITLE:-}"
ISSUE_BODY="${ISSUE_BODY:-}"
PROMPT="Initial prompt."

# Mock gh for issue body fetches (unused by depth-rule-append directly, but present for safety)
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

export PROMPT
