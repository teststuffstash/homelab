# ── bridge ── the per-repo loop variables the C6 merged-closeout clause holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `default_branch`, `c6g`, `c6g_nums`,
# `c6db`, `c6db_nums`, `units`, `items`, `orphans`, `dispatchable`) — a bridge that invents one
# pins a different clause.
#
# `closed_ip` is fetched INSIDE the block via `gh issue list --state closed`; the gh stub serves
# it from world/gh/ files. `c6g` and `c6g_nums` are set by the FU-143 detection block above; for
# this fixture they are empty (no goal children). `c6db` and `c6db_nums` are set by the IL-G06
# detection block above; for this fixture they are populated by the bridge to simulate the
# detection result.
#
# The bridge provides the loop context variables.
slug="teststuffstash/homelab"
repo="homelab"
default_branch="master"
dispatchable=1
units=""
items=""
orphans=""
# c6g is empty — no goal children in this fixture
c6g=""
c6g_nums=""
# c6db is pre-populated with the issues that have strong-link merged PRs
# #90 has Implements #90 in merged PR #200 into master
# #91 has Fixes #91 in merged PR #201 into master
c6db="90\n91\n"
c6db_nums="90 91 "
ISSUE_LIST_LIMIT=200

# Stub for item_class_push — the real function is defined in the scan's outer scope and not
# available in the extracted block. This stub just records the call for the action stream.
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  echo "item_class_push: $repo $item $class $who" >&2
}