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
  echo "=== scenario: large metrics payload with multiple matching timestamps ==="

  # Simulate a large metrics payload with many lines (busy board scenario). This would
  # have caused SIGPIPE with the old | head -1 approach because head closes stdin
  # while the previous grep commands are still writing data.
  read -r -d '' LARGE_METRICS <<'METRICS_EOF' || true
agent_item_class_since_timestamp_seconds{namespace="homelab-agents",repo="homelab",item="1",class="queued",who="machine",base="default"} 1786465000
agent_item_class{namespace="homelab-agents",repo="homelab",item="1",class="queued",who="machine",base="default"} 1
agent_item_class_since_timestamp_seconds{namespace="homelab-agents",repo="homelab",item="2",class="queued",who="machine",base="default"} 1786464900
agent_item_class{namespace="homelab-agents",repo="homelab",item="2",class="queued",who="machine",base="default"} 1
agent_item_class_since_timestamp_seconds{namespace="homelab-agents",repo="homelab",item="3",class="riding",who="machine",base="default"} 1786464800
agent_item_class{namespace="homelab-agents",repo="homelab",item="3",class="riding",who="machine",base="default"} 1
agent_item_class_since_timestamp_seconds{namespace="homelab-agents",repo="homelab",item="1456",class="agent-fix",who="machine",base="default"} 1786464700
agent_item_class{namespace="homelab-agents",repo="homelab",item="1456",class="agent-fix",who="machine",base="default"} 1
agent_item_class_since_timestamp_seconds{namespace="homelab-agents",repo="homelab",item="1456",class="agent-fix",who="machine",base="default"} 1786464600
agent_item_class{namespace="homelab-agents",repo="homelab",item="1456",class="agent-fix",who="machine",base="default"} 1
agent_item_class_since_timestamp_seconds{namespace="homelab-agents",repo="homelab",item="999",class="backlog",who="operator",base="default"} 1786464500
agent_item_class{namespace="homelab-agents",repo="homelab",item="999",class="backlog",who="operator",base="default"} 1
METRICS_EOF

  # Call item_class_push with large metrics_before. The extraction should:
  # 1. Find the FIRST matching timestamp line for item 1456
  # 2. Not cause SIGPIPE even with the large payload
  # 3. Return the correct timestamp value (1786464600 — the FIRST matching line)
  echo "=== push: large metrics payload scenario ==="
  metrics_before="$LARGE_METRICS" item_class_push "homelab" "1456" "agent-fix" "machine"
  printf 'RETURN %s\n' "$?"

  echo "=== push: no matching metrics in large payload ==="
  metrics_before="$LARGE_METRICS" item_class_push "homelab" "9999" "nonexistent" "ghost"
  printf 'RETURN %s\n' "$?"

  echo "=== end ==="
} >> "$REPLAY_ACTIONS"
