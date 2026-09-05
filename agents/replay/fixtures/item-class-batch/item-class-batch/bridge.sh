# ── bridge ── test the item_class_push accumulation and item_class_flush batching.
#
# The test accumulates multiple rows and then flushes them in one curl call.
# A real GET precedes the POST to retrieve existing metrics for timestamp carry-over.

sp_now() { printf '1786465900'; }

ITEM_CLASS_ROWS=""  # Initialize the accumulator (set by the extracted block definition)
CURL_GET_BODY=""   # Initialize the GET response (may be seeded by scenarios)
CURL_RC=0          # Initialize the curl return code

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  case "$*" in */metrics\?*) printf '%s\n' "$CURL_GET_BODY"; return 0 ;; esac
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

{
  echo "=== scenario 1: accumulate and flush new items ==="
  item_class_push "homelab" "833" "held-merged-unlinked" "operator"
  item_class_push "homelab" "834" "queued-held-by-ghost" "operator"
  item_class_push "homelab" "889" "riding" "machine"
  item_class_push "homelab" "840" "container" "none"
  item_class_push "homelab" "aggregate" "backlog-aggregate" "operator"
  printf 'ACCUMULATED %s\n' "$(printf '%b' "$ITEM_CLASS_ROWS" | wc -l)"

  echo "=== flush batch to pushgateway ==="
  item_class_flush
  printf 'FLUSH_DONE %s\n' "$?"

  echo "=== scenario 2: timestamp carry-over for unchanged items ==="
  # ADR-125: the stored rows carry the lane `base` too, because the carry-over lookup matches on
  # the FULL label set the row is pushed with. Seeded WITH base= so the hit still happens; the
  # anti-vacuity check is scenario 3, where only the base differs and the row must re-stamp.
  CURL_GET_BODY="# HELP agent_item_class_since_timestamp_seconds Unix epoch when classified
# TYPE agent_item_class_since_timestamp_seconds gauge
agent_item_class_since_timestamp_seconds{repo=\"homelab\",item=\"833\",class=\"held-merged-unlinked\",who=\"operator\",base=\"master\"} 1786000000
agent_item_class_since_timestamp_seconds{repo=\"homelab\",item=\"834\",class=\"queued-held-by-ghost\",who=\"operator\",base=\"master\"} 1786100000"

  item_class_push "homelab" "833" "held-merged-unlinked" "operator"
  item_class_push "homelab" "835" "riding" "machine"
  printf 'ACCUMULATED %s\n' "$(printf '%b' "$ITEM_CLASS_ROWS" | wc -l)"

  echo "=== flush with timestamp preservation ==="
  item_class_flush
  printf 'FLUSH_DONE %s\n' "$?"

  # ── ADR-125: the lane is part of the identity, not decoration ────────────────────────────────
  # The SAME (repo, item, class, who) as the seeded row above, in a DIFFERENT lane. An item that
  # moved from master to a goal branch has not been sitting in the goal lane since 1786000000, so
  # the carry-over must MISS and the row must re-stamp at `now` (1786465900). Delete `base` from
  # the carry-over grep in item_class_flush and this row goes red — that is the point of it.
  echo "=== scenario 3: a lane change re-stamps (carry-over matches on base) ==="
  item_class_push "homelab" "833" "held-merged-unlinked" "operator" "goal/278"
  item_class_flush
  printf 'FLUSH_DONE %s\n' "$?"

  echo "=== end ==="
} >> "$REPLAY_ACTIONS"
