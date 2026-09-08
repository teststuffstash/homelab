# ── bridge ── simulate large metrics payload (the busy board scenario).
#
# Test that the extraction pipeline handles large payloads without SIGPIPE. The old
# code used | head -1 which would close stdin early on large data, causing exit 141
# (SIGPIPE) under pipefail. The fixed code captures full output first, then extracts
# the first line via parameter expansion.

sp_now() { printf '1786465900'; }

curl() {
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  while IFS= read -r l; do printf 'STDIN %s\n' "$l" >> "$REPLAY_ACTIONS"; done
  return "${CURL_RC:-0}"
}

{
  echo "=== scenario: large metrics payload (busy board) with many matching base=default lines ==="

  # Generate a LARGE metrics payload that simulates a busy board day with hundreds of items.
  # The old code (base) uses | head -1 which closes stdin early. With many grep filters and
  # a large payload, this causes head to close the pipe before all previous commands finish
  # writing, triggering SIGPIPE (exit 141) in one of the greps under pipefail.
  # The fixed code captures full output first, avoiding the early-close problem.
  LARGE_METRICS=""
  for i in {1..200}; do
    LARGE_METRICS="${LARGE_METRICS}agent_item_class{namespace=\"homelab-agents\",repo=\"homelab\",item=\"$i\",class=\"queued\",who=\"machine\",base=\"default\"} 1
"
    LARGE_METRICS="${LARGE_METRICS}agent_item_class_since_timestamp_seconds{namespace=\"homelab-agents\",repo=\"homelab\",item=\"$i\",class=\"queued\",who=\"machine\",base=\"default\"} 178646$((5000 - i))
"
  done
  # Add the target item with TWO matching lines (to make head -1 necessary, not just useful)
  LARGE_METRICS="${LARGE_METRICS}agent_item_class_since_timestamp_seconds{namespace=\"homelab-agents\",repo=\"homelab\",item=\"1456\",class=\"agent-fix\",who=\"machine\",base=\"default\"} 1786464700
agent_item_class{namespace=\"homelab-agents\",repo=\"homelab\",item=\"1456\",class=\"agent-fix\",who=\"machine\",base=\"default\"} 1
agent_item_class_since_timestamp_seconds{namespace=\"homelab-agents\",repo=\"homelab\",item=\"1456\",class=\"agent-fix\",who=\"machine\",base=\"default\"} 1786464600
agent_item_class{namespace=\"homelab-agents\",repo=\"homelab\",item=\"1456\",class=\"agent-fix\",who=\"machine\",base=\"default\"} 1
"

  # Call item_class_push with large metrics_before. The extraction should:
  # 1. With the fix: capture full pipeline output, then extract first line via parameter expansion (no SIGPIPE).
  # 2. Without the fix: use | head -1 which closes stdin early → SIGPIPE from grep under pipefail (exit 141).
  echo "=== push: LARGE payload with 200+ items (busy board scenario) ==="
  metrics_before="$LARGE_METRICS" item_class_push "homelab" "1456" "agent-fix" "machine"
  printf 'RETURN %s\n' "$?"

  echo "=== end ==="
} >> "$REPLAY_ACTIONS"
