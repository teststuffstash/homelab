# ── bridge ── case 1: stamp at head + leaked label
# PR #10: labels major+dependencies+automerge, un-armed; the reviewer bot's APPROVED carries the
# reflex's literal body and was submitted AFTER the one content commit (an update-branch merge
# commit sits on top — not content). Expected: dismissal + label strip + event line.
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "2026-09-28T09:00:00Z"; }

slug="teststuffstash/homelab"
repo="homelab"
orphans=""
units=""
item_class_push() { :; }

echo "REACHED: case 1 — reflex stamp at head + leaked automerge label ⇒ dismissed + stripped"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list-openall.json")"
