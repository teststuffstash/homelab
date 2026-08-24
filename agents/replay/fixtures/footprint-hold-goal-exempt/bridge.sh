# ── bridge ── the scan state the footprint-hold block reads. Every name is a variable the shipped
# script sets before the queued loop (`HERE`, `busy_fps`, `wip_busy`), never a harness invention.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
# Simulate `$inprog` as the scan builds it — two issues: one fix-class with chassis/** and
# docs/**, and one goal-class (task/goal label) with no body. The real construction at
# agents/coordinator-scan.sh L851 filters goal issues OUT of busy_fps via a jq select
# (homelab#822 direction 2: a goal holds no sibling), so only the fix issue's footprint enters
# busy_fps. A non-goal sentinel issue (no Touches:) would yield `*` — here neither issue does,
# so busy_fps stays as `chassis/**,docs/**`.
inprog='[
  {"number": 999, "title": "a fix issue", "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}], "body": "Touches: chassis/**\nTouches: docs/**"},
  {"number": 888, "title": "a goal issue", "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}, {"name": "task/goal"}], "body": ""}
]'
# The same jq pipeline as the scan — select excludes task/goal issues.
busy_fps="$(printf '%s' "$inprog" | jq -r '.[]
  | select(((.labels|map(.name))|index("task/goal"))|not)
  | ([(.body // "") | scan("(?mi)^[ \\t]*touches:[ \\t]*(.+)$")] | flatten | join(","))
  | if . == "" then "*" else . end')"
# WIP ceiling check must be non-triggering for these tests
wip_busy=""
# orphans accumulator — the footprint-hold block appends to it
orphans=""