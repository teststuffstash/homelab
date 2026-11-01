# ── bridge (homelab#1910, changes-requested rows) ── the per-repo loop variables the
# changes-requested clause reads (`slug`, `repo`, `prsjson`, `openall`, the holds' inputs).
# `prsjson` is the `gh pr list` payload the scan already holds, so it arrives as a world file.
. "$REPLAY_ROOT/agents/machine-comment.sh"
mc_now() { printf '%s\n' "${MC_NOW:?fixture must pin MC_NOW}"; }
. "$REPLAY_ROOT/agents/pr-last-edited.sh"
slug="$IN_SLUG"
repo="$IN_REPO"
prsjson="$(cat "$REPLAY_WORLD/gh/pr-list.json")"
openall="$(cat "$REPLAY_WORLD/gh/openall.json")"
orphans=""; units=""; items=""; noop_units=""
# No live worker / session / WIP pressure: the no-op leg is reached only with all holds clear.
WIPPODS_JSON='{"items":[]}'
wip_busy=""
sess_holds() { return 1; }
item_class_push() { :; }
