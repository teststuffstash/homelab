# ── bridge ── the per-repo loop variables the C6 merged-closeout clause holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `c6g`, `c6db`, `units`, `items`,
# `orphans`) — a bridge that invents one pins a different clause.
#
# `closed_ip` is fetched INSIDE the block via two `gh issue list --state closed --label <state>`
# reads; the gh stub serves BOTH from world/gh/issue-list.json (the stub's world key drops the
# `--label` value), so the clause's merge-by-number is what keeps each issue to one unit.
# `c6g` / `c6db` are the FU-143 / IL-G06 detections above the block — empty here: this fixture
# pins the closed-issue selector only.
slug="teststuffstash/homelab"
repo="homelab"
units=""
items=""
orphans=""
c6g=""
c6db=""

# The real item_class_push lives in the scan's outer scope, outside the extracted block.
item_class_push() {
  echo "item_class_push: $1 $2 $3 $4" >&2
}
