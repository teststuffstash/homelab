# ── bridge ── the scan state the pr-cap-per-base block reads.
REPO_PR_CAP="${REPO_PR_CAP:-3}"
# FU-199 / #1240 CAP SPLIT: codeowner-parked PRs count against their own bound.
REPO_BLOCKPARK_CAP="${REPO_BLOCKPARK_CAP:-5}"
# Collision case with blockpark: `big-master|7` and `master|1` for armed PRs,
# and `master|10` for blockpark PRs. The awk exact-field match picks `master|1`
# (1 < cap 3) for the PR budget check, but `master|10` (10 ≥ cap 5) triggers
# the blockpark hold.
per_base_armed="big-master|7
master|1"
per_base_blockpark="master|10"
default_branch="master"
orphans=""
# item_class_push — the scan's per-pass accumulator. Defined here because the extracted
# pr-cap-per-base block now calls it for blockpark items (FU-199 / #1240).
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}
ITEM_CLASS_ROWS=""