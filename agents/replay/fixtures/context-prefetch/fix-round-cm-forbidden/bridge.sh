# ── bridge ── fix round, ConfigMap create REFUSED (homelab#1386 codeowner read): same world as
# ../fix-round (pr.md + reviews.md fetch OK, no failing check runs), but STUB_KUBECTL_create=fail
# (fixture.yaml) makes the `kubectl create -f -` for the context bundle fail, forcing the argv
# fallback. Exercises the two-file fallback (index.txt + issue.md) and the MISSING-downgrade of
# the optional items that DID fetch (pr.md, reviews.md) — ci-failure.md's pre-existing MISSING
# ("No failing check runs found") must stay untouched, proving the downgrade only fires on OK.
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
