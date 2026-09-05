# Bridge for merge-conflict with agent/blocked source issue hold test
# This tests acceptance item 1: a merge-conflict unit is not emitted while its source issue is agent/blocked

slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
openall="$(cat "$REPLAY_WORLD/gh/issues-list.json")"
orphans=""
units=""

# Stubs for FU-146 per-item hold and other shared logic
WIPPODS_JSON='{"items":[]}'
wip_busy=""
sess_holds() { return 1; }

# Stub functions
item_class_push() { :; }
pr_blocked_on_check() { printf 'clear\n'; }  # No blocked-on markers in this test
state_fp_for_clause() {
  local clause="$1" fp_probe="$2"
  local clause_marker hash
  # Try to find clause-scoped marker first: state-fp:<clause>:<hash>
  clause_marker="$(printf '%s' "$fp_probe" | jq -r --arg c "$clause" \
    '([ .comments[]? | select((.body // "") | test("state-fp:" + $c + ":[0-9a-f]{6,64}")) ]
      | sort_by(.createdAt) | last // {})
     | (((.body // "") | [ scan("state-fp:" + $c + ":([0-9a-f]{6,64})") ] | .[0]) // "")' 2>/dev/null)" || clause_marker=""
  if [ -n "$clause_marker" ]; then
    printf '%s' "$clause_marker"
    return 0
  fi
  # Fall back to old format: state-fp:<hash> (backwards compatibility)
  hash="$(printf '%s' "$fp_probe" | jq -r \
    '([ .comments[]? | select((.body // "") | test("state-fp:[0-9a-f]{6,64}")) ]
      | sort_by(.createdAt) | last // {})
     | (((.body // "") | [ scan("state-fp:([0-9a-f]{6,64})") ] | last) // "")' 2>/dev/null)" || hash=""
  printf '%s' "$hash"
}
