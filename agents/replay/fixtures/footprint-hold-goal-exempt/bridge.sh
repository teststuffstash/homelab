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
# ITEM_CLASS_ROWS accumulator — initialized here so the extracted clause block can append to it.
ITEM_CLASS_ROWS=""
# item_class_push — the scan's per-pass accumulator. Defined here because the extracted
# footprint-hold block now calls it for held items (FU-199 / #1240).
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  ITEM_CLASS_ROWS="${ITEM_CLASS_ROWS}${repo}|${item}|${class}|${who}|...\n"
}

# ADR-125: `item_class_push` rows carry the item's LANE base. The queued clause passes its own
# `$qbase` (the issue's `Base:` line, defaulted to the repo default branch — the same value the
# homelab#849 per-base cap reads); this bridge replays a default-branch issue.
qbase="${qbase:-master}"
