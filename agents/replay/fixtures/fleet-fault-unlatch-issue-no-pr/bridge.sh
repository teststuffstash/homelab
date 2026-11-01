# gh_label_add / gh_label_rm — the shipped REST label transport the clause calls (FU-290); sourced, never stubbed.
. "$REPLAY_ROOT/agents/machine-comment.sh"
# ── bridge ── issue-side, no-PR case
# Issue #100 has agent/error label with fleet-fault marker (cause=homelab#1000, CLOSED).
# No open PR references #100, and the open-PR list read succeeded (prsjson_read_ok=1 — the
# real read at the top of the scan sets it; this bridge stands in for that read).
# Expected: agent/error label REMOVED from issue #100, comment names the vacuous CI leg.

slug="teststuffstash/homelab"
repo="homelab"
dispatchable=1
orphans=""
item_class_push() { :; }

echo "REACHED: issue case — fleet-fault marker + cause closed + no referencing PR (list read ok) ⇒ label removed, CI leg vacuous"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
prsjson_read_ok=1
openall="$(cat "$REPLAY_WORLD/gh/issue-list-openall.json")"
