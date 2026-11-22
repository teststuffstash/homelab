# ── bridge ── the block reads OPEN_PR/MERGED_PR (two `gh pr list` reads above it) and the run
# coordinates; rows set the PR state and GIT_DIFF_RC (does the branch differ from master?).
STACK="${STACK:?}"; RUN="${RUN:?}"; N="${N:?}"; BR="${BR:?}"; DEAD_NOTE="${DEAD_NOTE:-}"
OPEN_PR="${OPEN_PR:-}"; MERGED_PR="${MERGED_PR:-}"
# The report repo's coordinates (set above the block from reportRepo/reportDir + the clone's
# default branch) and the second leg's harness (a two-cell run names the cross-review legs).
REPORT_REPO="${REPORT_REPO:-teststuffstash/homelab}"; REPORT_DIR="${REPORT_DIR:-docs/agents/retros}"
REPORT_BASE="${REPORT_BASE:-master}"; HARNESS_B="${HARNESS_B-goose}"

# ── git seam ── record every call; `git diff --quiet` answers GIT_DIFF_RC.
git() {
  printf 'CALL git %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$1" in diff) return "${GIT_DIFF_RC:-1}" ;; esac
}
