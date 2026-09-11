# ── bridge ── probe-fail case
# PR #13 has agent/error label with fleet-fault marker, but PR view probe FAILS
# Expected: agent/error label HELD (rule #6; unreadable probe)

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: case 4 — probe fails ⇒ label held (rule #6)"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
