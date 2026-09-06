# ── bridge ── the per-repo loop variables the goal-lane clause reads.
slug="$IN_SLUG"
repo="$IN_REPO"
ORG="${slug%/*}"
# ── world data ── issue list (goal + members) and findings store.
openall="$(cat "$REPLAY_WORLD/gh/issue-list.json")"
prsjson='[]'
kidsall="$(cat "$REPLAY_WORLD/gh/issue-tree.json")"
# ── stubs ── suppress unrelated clauses and provide minimal env.
orphans=""
units=""
REPO_CAP=5
ISSUE_LIST_LIMIT=100
GOAL_CHECKPOINT_N=5
GOAL_TERMINAL_MAX=20
# Stubs for functions called in goal-lane
item_class_push() { :; }
# ── override date ── deterministic timestamp for marker comments.
date() {
  if [ "$1" = "-u" ] && [ "$2" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
    printf '2026-09-06T02:00:00Z'
  else
    command date "$@"
  fi
}
