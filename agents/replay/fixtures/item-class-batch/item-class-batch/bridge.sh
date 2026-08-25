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

  echo "=== end ==="
} >> "$REPLAY_ACTIONS"
