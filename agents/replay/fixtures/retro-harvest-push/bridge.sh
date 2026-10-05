# ── bridge ── the block reads OPEN_PR/MERGED_PR (two `gh pr list` reads above it) and the run
# coordinates; rows set the PR state and GIT_DIFF_RC (does the branch differ from master?).
STACK="${STACK:?}"; RUN="${RUN:?}"; N="${N:?}"; BR="${BR:?}"; DEAD_NOTE="${DEAD_NOTE:-}"
OPEN_PR="${OPEN_PR:-}"; MERGED_PR="${MERGED_PR:-}"

# ── git seam ── record every call; `git diff --quiet` answers GIT_DIFF_RC.
git() {
  printf 'CALL git %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$1" in diff) return "${GIT_DIFF_RC:-1}" ;; esac
}
