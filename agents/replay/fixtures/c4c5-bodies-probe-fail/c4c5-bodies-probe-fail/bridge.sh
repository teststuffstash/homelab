# ── bridge ── the per-repo loop variables the C4/C5 BODIES guard reads. Every name is a SCAN name
# (`slug`, `repo`, `orphans`) — a bridge that invents one pins a different clause.
#
# The guard RUNS the open-PR body probe itself (`gh pr list`, stubbed and failed by `STUB_GH=fail`)
# — that is the code under replay — so it does NOT arrive as a recorded file the way `inprog` /
# `BODIES` do for the selector/derivations blocks. `units` / `v2` / `infeas_done` are set to empty
# only because the shared observation point (post.sh) prints them and this fixture never reaches
# the blocks that would have set them; the guard's `then` branch (the whole C4/C5 clause) is
# deliberately not executed on this leg.
slug="teststuffstash/homelab"
repo="homelab"
orphans=""
units=""
v2=""
infeas_done=""

# ── stub ── item_class_push is defined in the item-class block; the c4c5-bodies-probe block calls it
item_class_push() {
  printf 'CALL item_class_push %s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$REPLAY_ACTIONS"
}
