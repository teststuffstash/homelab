# ── bridge ── fix round (WORK_BRANCH + PF_PR set); ARBITRATE comments on both the issue
# and the PR conversation — see fixture.yaml for which is newer.
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
