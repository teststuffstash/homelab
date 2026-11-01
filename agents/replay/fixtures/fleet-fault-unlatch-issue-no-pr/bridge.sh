# Issue #100 has agent/error label with fleet-fault marker (cause=homelab#1000, CLOSED); no open PR references #100
# (PR #21 is for #200). The open-PR list was read successfully (prsjson_fetch_rc=0).
# Expected: agent/error label REMOVED from issue #100; the comment says the CI leg is vacuous (no PR), not green.
. "$REPLAY_ROOT/agents/machine-comment.sh"

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: issue case — fleet-fault marker + cause closed + PR-less + PR list read ⇒ label removed (CI leg vacuous)"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
prsjson_fetch_rc=0
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
