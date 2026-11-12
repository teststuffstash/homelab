# ── bridge ── the per-repo scan state the ci-red clause holds when its PR loop starts (shared by
# the family rows). Every name is a variable the shipped script sets before the loop — never a
# harness invention. The loop header, the PR selection and `red_issue` arrive as the extracted
# `block:ci-red-select`; `u_head`, the lane read, the settling hold and the debounce as
# `block:assembly-ci-red`; the report line as `block:ci-red-goal-head-exclusion`.
#
# `HERE` points at the real `agents/` in the checkout, so `classify_touches_repo` is the ONE
# definition in footprint.sh reading the checkout's real CODEOWNERS (the scan-governance seam) and
# `goal_resolve_ancestor` is the real walk over the recorded world. Nothing here names a path lane.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
GUARDED_REPO="homelab"
WORKER_AUTHOR="app/homelab-agents-1234"
slug="$IN_SLUG"
repo="$IN_REPO"
# The scan's `gh pr list … --json number,labels,author,autoMergeRequest,headRefOid,headRefName,statusCheckRollup,body`.
red_probe="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
assembly_red_prs=""
default_branch="master"
item_class_push() { :; }
# the SETTLING hold's clock: pinned, `:?`-guarded — a defaulted clock asserts against an accident.
um_now() { date -u -d "${IN_NOW:?the row pins the clock}" +%s; }
