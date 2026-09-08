# ── bridge ── cause-closed-green case
# PR #10 has agent/error label with fleet-fault marker (cause=homelab#1000, CI green)
# Expected: agent/error label REMOVED

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: case 1 — fleet-fault marker + cause closed + green CI ⇒ label removed"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
