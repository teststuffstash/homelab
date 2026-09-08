# ── bridge ── cause-open case
# PR #11 has agent/error label with fleet-fault marker (cause=homelab#1001 still OPEN, CI green)
# Expected: agent/error label HELD (not removed)

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: case 2 — fleet-fault marker + cause still OPEN ⇒ label held"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
