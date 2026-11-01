# Issue #100 has agent/error label with fleet-fault marker (cause=homelab#1000, CLOSED). The open-PR list
# FAILED to read: the scan's '[]' fallback (prsjson_fetch_rc=1) must NOT be taken as "no PR".
# Expected: HOLD line, no label write.
. "$REPLAY_ROOT/agents/machine-comment.sh"

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: issue case — fleet-fault marker + cause closed + PR list unreadable ⇒ HOLD, no write"
prsjson='[]'
prsjson_fetch_rc=1
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
