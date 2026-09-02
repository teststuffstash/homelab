# ── bridge ── the scan state the pr-cap-per-base block reads.
REPO_PR_CAP="${REPO_PR_CAP:-3}"
# FU-199 / #1240 CAP SPLIT: codeowner-parked PRs count against their own bound.
REPO_BLOCKPARK_CAP="${REPO_BLOCKPARK_CAP:-10}"
per_base_blockpark=""
# Collision case: `big-master|7` and `master|1`. The old grep -F substring match
# would pick `big-master|7` (7 ≥ cap 3) and wrongly hold the queued issue.
# awk exact-field match picks `master|1` (1 < cap 3) → DISPATCHED.
per_base_armed="big-master|7
master|1"
default_branch="master"
orphans=""