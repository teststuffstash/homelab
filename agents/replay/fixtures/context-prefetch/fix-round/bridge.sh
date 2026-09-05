# ── bridge ── fix round: WORK_BRANCH and PF_PR are set so the context-prefetch block
# fetches PR data + reviews + inline comments in addition to the issue + comments.
RUN_CMD="goose run --recipe .agents/fix.yaml --params issue=1175"
TASK="issue-1175"
NS="agent-runs"
PROJECT="test-project"
REPO_URL="https://github.com/teststuffstash/test-project.git"
PF_ISSUE="1175"
PF_SLUG="teststuffstash/test-project"
PF_PR="42"
WORK_BRANCH="fix/issue-1175-test"
KUBECTL="kubectl"
KUBE=""
POD="agent-test-project-issue-1175-r1"