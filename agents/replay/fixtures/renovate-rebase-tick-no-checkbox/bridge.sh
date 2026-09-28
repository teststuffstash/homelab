# ── bridge ── the per-repo scan variables the clause reads
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "2026-09-28T09:00:00Z"; }

slug="teststuffstash/homelab"
repo="homelab"
orphans=""
units=""
item_class_push() { :; }

prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
