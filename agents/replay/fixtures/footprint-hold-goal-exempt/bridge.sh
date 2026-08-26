# ── bridge ── the scan state the footprint-hold block reads. Every name is a variable the shipped
# script sets before the queued loop (`HERE`, `busy_fps`, `wip_busy`), never a harness invention.
HERE="$REPLAY_ROOT/agents"
. "${HERE}/footprint.sh"
# Simulate `$inprog` as the scan builds it — two issues: one fix-class with chassis/** and
# docs/**, and one goal-class (task/goal label) with no body. The `>>>REPLAY:busy-fps>>>` block
# (extracted from coordinator-scan.sh) reads this mock and constructs `busy_fps` from the shipped
# jq pipeline — no hand-duplicated select remains.
inprog='[
  {"number": 999, "title": "a fix issue", "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}], "body": "Touches: chassis/**\nTouches: docs/**"},
  {"number": 888, "title": "a goal issue", "labels": [{"name": "agent-fix"}, {"name": "agent/in-progress"}, {"name": "task/goal"}], "body": ""}
]'
# WIP ceiling check must be non-triggering for these tests
wip_busy=""
# orphans accumulator — the footprint-hold block appends to it
orphans=""