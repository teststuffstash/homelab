# ── bridge ── issue-side case
# Issue #100 has agent/error label with fleet-fault marker (cause=homelab#1000, CI green via PR #20)
# PR #20 fixes issue #100 and has green CI
# Expected: agent/error label REMOVED from issue #100

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: issue case — fleet-fault marker + cause closed + green CI on referencing PR ⇒ label removed"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"

