# ── bridge ── test the queued-classification logic under set -u
#
# This bridge re-implements the queued-issue classification logic from agents/coordinator-scan.sh
# with controlled variable inputs to verify correct behavior under set -euo pipefail.
# The logic being tested is from lines 1635-1648:
#   if [ -z "$qdeps" ]; then
#     qclass_item="queued-ready"
#   else
#     qclass_item="queued-held"
#   fi
#   (dispatch unit construction and item_class_push call)

# Shim item_class_push to capture the calls
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}

{
  echo "=== scenario 1: queued issue with no blockers (qdeps empty after dash normalization) ==="
  repo="homelab"
  qnum="100"
  qdeps="-"   # placeholder for "no blockers"
  qpin="-"    # not pinned
  qclass="fix"
  qparent=""
  units=""
  punits=""

  # Normalize qdeps from "-" to empty (agents/coordinator-scan.sh line 1448)
  [ "$qdeps" = "-" ] && qdeps=""

  # Quoted from agents/coordinator-scan.sh line 1635-1646:
  # Classify the queued issue based on blocker status (qdeps is normalized to empty if "-")
  if [ -z "$qdeps" ]; then
    qclass_item="queued-ready"
  else
    qclass_item="queued-held"
  fi
  if [ "$qpin" = "P" ]; then
    punits="${punits}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  else
    units="${units}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  fi
  item_class_push "$repo" "issue-${qnum}" "$qclass_item" "machine"
  printf 'RESULT scenario=1 classification=%s\n' "$qclass_item"

  echo "=== scenario 2: queued issue with blockers (qdeps non-empty) ==="
  qnum="101"
  qdeps="homelab#99, homelab#100"  # non-empty blocker list
  qpin="-"
  qclass="fix"
  qparent=""
  units=""
  punits=""

  if [ -z "$qdeps" ]; then
    qclass_item="queued-ready"
  else
    qclass_item="queued-held"
  fi
  if [ "$qpin" = "P" ]; then
    punits="${punits}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  else
    units="${units}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  fi
  item_class_push "$repo" "issue-${qnum}" "$qclass_item" "machine"
  printf 'RESULT scenario=2 classification=%s\n' "$qclass_item"

  echo "=== scenario 3: pinned queued-ready issue ==="
  qnum="102"
  qdeps=""      # empty = ready
  qpin="P"      # pinned
  qclass="fix"
  qparent=""
  units=""
  punits=""

  if [ -z "$qdeps" ]; then
    qclass_item="queued-ready"
  else
    qclass_item="queued-held"
  fi
  if [ "$qpin" = "P" ]; then
    punits="${punits}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  else
    units="${units}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  fi
  item_class_push "$repo" "issue-${qnum}" "$qclass_item" "machine"
  printf 'RESULT scenario=3 classification=%s pinned=true\n' "$qclass_item"

  echo "=== scenario 4: queued-held with parent issue ==="
  qnum="103"
  qdeps="homelab#99"  # has blockers
  qpin="-"
  qclass="fix"
  qparent="105"       # has parent issue
  units=""
  punits=""

  if [ -z "$qdeps" ]; then
    qclass_item="queued-ready"
  else
    qclass_item="queued-held"
  fi
  if [ "$qpin" = "P" ]; then
    punits="${punits}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  else
    units="${units}queued-dispatch|${repo}|issue-${qnum}|${qclass}${qparent:+|${qparent}}\n"
  fi
  item_class_push "$repo" "issue-${qnum}" "$qclass_item" "machine"
  printf 'RESULT scenario=4 classification=%s has_parent=true\n' "$qclass_item"

  echo "=== end ==="
} >> "$REPLAY_ACTIONS"
