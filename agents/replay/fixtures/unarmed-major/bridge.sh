# ── bridge ── the per-repo scan variables the unarmed-major clause reads (shared by the family rows)
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
orphans=""
units=""
item_class_push() { :; }
# blocked-on predicate: the family's world decides — a row with a `blocked-on: human` comment is held
pr_blocked_on_check() {
  local slug="$1" u="$2" pr_json="$3" m
  m="$(printf '%s' "$pr_json" | jq -r '[.comments[]? | select((.body // "") | test("^blocked-on: human"))] | length' 2>/dev/null || echo 0)"
  if [ "${m:-0}" -gt 0 ]; then printf 'blocked|human (a blocked-on: human marker with no later human comment)\n'; else printf 'clear\n'; fi
}
# state_fp_for_clause comes from block:state-fp-jq (the real reader) — never stub it here
