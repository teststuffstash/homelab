# ── bridge ── no-marker case
# PR #12 has agent/error label but AGENT_ERROR comment has NO fleet-fault marker
# Expected: agent/error label HELD (no un-latch; human-first)

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: case 3 — no fleet-fault marker ⇒ label held (human-first)"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
