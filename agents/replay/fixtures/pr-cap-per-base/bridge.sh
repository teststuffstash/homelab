# ── bridge ── the scan state the pr-cap-per-base block reads. Every name is a variable the shipped
# script sets before the queued loop (`per_base_armed`, `REPO_PR_CAP`, `default_branch`), never a
# harness invention.
REPO_PR_CAP="${REPO_PR_CAP:-3}"
# Simulate two armed PRs against master and one against goal/29-p0-complete.
# This matches the real prsjson shape: baseRefName + autoMergeRequest != null.
per_base_armed="master|3
goal/29-p0-complete|1"
# Default branch: queued issues without a `Base:` body line count against this.
default_branch="master"
# orphans accumulator — the pr-cap-per-base block appends to it
orphans=""