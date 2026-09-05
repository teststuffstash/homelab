# ── bridge ── the per-repo loop variables the merge-conflict clause reads. Same shape as the
# clause fixture's bridge; this family reuses it so the debounce half differs only in its world.
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
# ── stubs ── variables and functions the merge-conflict clause reads
openall='[]'
WIPPODS_JSON='{"items":[]}'
wip_busy=""
sess_holds() { return 1; }
pr_blocked_on_check() { printf 'clear\n'; }
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
    '([ .comments[]? | select((.body // "") | test("state-fp:[0-9a-z:-]*[0-9a-f]{6,64}")) ]
      | sort_by(.createdAt) | last // {})
     | (((.body // "") | [ scan("state-fp:[0-9a-z:-]*([0-9a-f]{6,64})") ] | last) // "")' 2>/dev/null)" || hash=""
  printf '%s' "$hash"
}
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }
