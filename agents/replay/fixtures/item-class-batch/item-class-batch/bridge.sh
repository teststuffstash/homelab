# ── bridge ── test the item_class_push accumulation and item_class_flush batching.
#
# The test accumulates multiple rows and then flushes them in one curl call.
# A real GET precedes the POST to retrieve existing metrics for timestamp carry-over.

sp_now() { printf '1786465900'; }

ITEM_CLASS_ROWS=""  # Initialize the accumulator (set by the extracted block definition)

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

{
  echo "=== accumulate multiple rows ==="
  item_class_push "homelab" "833" "held-merged-unlinked" "operator"
  item_class_push "homelab" "834" "queued-held-by-ghost" "operator"
  item_class_push "homelab" "889" "riding" "machine"
  item_class_push "homelab" "840" "container" "none"
  item_class_push "homelab" "aggregate" "backlog-aggregate" "operator"
  printf 'ACCUMULATED %s\n' "$(printf '%b' "$ITEM_CLASS_ROWS" | wc -l)"

  echo "=== flush batch to pushgateway ==="
  item_class_flush
  printf 'FLUSH_DONE %s\n' "$?"

  echo "=== end ==="
} >> "$REPLAY_ACTIONS"
