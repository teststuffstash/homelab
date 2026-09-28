# ── bridge ── case 2: a real lens verdict at head, no leaked label ⇒ untouched
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "2026-09-28T09:00:00Z"; }

slug="teststuffstash/homelab"
repo="homelab"
orphans=""
units=""
item_class_push() { :; }

echo "REACHED: case 2 — lens verdict at head, no leaked label ⇒ nothing written"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
