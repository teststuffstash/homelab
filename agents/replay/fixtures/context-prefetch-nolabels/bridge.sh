# ── bridge ── the launcher variables the context-prefetch block reads. RUN_CMD and TASK are set
# so the pre-flight guard's `case "$TASK" in issue-[0-9]*)` matches. PF_SLUG and PF_ISSUE are
# derived from REPO_URL and TASK inside the pre-flight block — set here for the extracted block.
#
# World: one issue (title, body, NO labels) + two comments (author, body, created_at).
# The fixture asserts the gh API calls, the prelude prepend to RUN_CMD, and the log line.
RUN_CMD="goose run --recipe .agents/fix.yaml --params issue=1175"
TASK="issue-1175"
NS="agent-runs"
PROJECT="test-project"
REPO_URL="https://github.com/teststuffstash/test-project.git"
PF_ISSUE="1175"
PF_SLUG="teststuffstash/test-project"
# kube.sh resolution: in the replay PATH-shim, kubectl is on $PATH via the stubs.
KUBECTL="kubectl"
KUBE=""
POD="agent-test-project-issue-1175-r1"