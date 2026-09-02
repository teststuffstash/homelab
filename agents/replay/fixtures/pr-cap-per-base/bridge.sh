# ── bridge ── the scan state the pr-cap-per-base block reads. Every name is a variable the shipped
# script sets before the queued loop (`per_base_armed`, `REPO_PR_CAP`, `default_branch`), never a
# harness invention.
REPO_PR_CAP="${REPO_PR_CAP:-3}"
# FU-199 / #1240 CAP SPLIT: codeowner-parked PRs count against their own bound.
REPO_BLOCKPARK_CAP="${REPO_BLOCKPARK_CAP:-10}"
per_base_blockpark=""
# Simulate two armed PRs against master and one against goal/29-p0-complete.
# This matches the real prsjson shape: baseRefName + autoMergeRequest != null.
per_base_armed="master|3
goal/29-p0-complete|1"
# Default branch: queued issues without a `Base:` body line count against this.
default_branch="master"
# orphans accumulator — the pr-cap-per-base block appends to it
orphans=""
# item_class_push — the scan's per-pass accumulator. Defined here because the extracted
# pr-cap-per-base block now calls it for cap-held items (FU-199 / #1240).
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
ITEM_CLASS_ROWS=""