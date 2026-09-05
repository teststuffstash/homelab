# ── bridge ── the per-repo loop variables the C6 merged-closeout clause holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `default_branch`, `c6g`, `c6g_nums`,
# `c6db`, `c6db_nums`, `units`, `items`, `orphans`, `dispatchable`) — a bridge that invents one
# pins a different clause.
#
# `closed_ip` is fetched INSIDE the block via `gh issue list --state closed`; the gh stub serves
# it from world/gh/ files. `c6g` and `c6g_nums` are set by the FU-143 detection block above; for
# this fixture they are empty (no goal children). `c6db` and `c6db_nums` are set by the IL-G06
# detection block above; this bridge does NOT pre-populate them — the detection block derives
# them from the (empty) merged-PR world, and that derivation is empty here. See fixture.yaml.
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
# goalcand is the OPEN issues with agent/in-progress or agent/review labels. The code
# derives dbcand from this by filtering out those with agent/error and with a Base: line.
# The three test issues (#90, #91, #92) all have agent/fix + (agent/in-progress|agent/review),
# no agent/error, and no Base: line, so they'll be candidates for the IL-G06 detection.
goalcand='[
  {"number": 90, "title": "test issue 90", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/in-progress"}]},
  {"number": 91, "title": "test issue 91", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/review"}]},
  {"number": 92, "title": "test issue 92", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/in-progress"}]}
]'
# dbmerged and dbopen are fetched by the IL-G06 detection block from the replay world.
# world/gh/pr-list.json has the merged PRs that the detection block will analyze.
# The detection block will derive c6db and c6db_nums from the fetched data.
# (Do NOT pre-populate them here — let the detection block do the work.)
ISSUE_LIST_LIMIT=200

# Stub for item_class_push — the real function is defined in the scan's outer scope and not
# available in the extracted block. This stub just records the call for the action stream.
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  echo "item_class_push: $repo $item $class $who" >&2
}

# ── seam (ADR-122 (3), homelab#1431) ── the ONE issue-body parser. The scan resolves it beside
# itself; a composition sees config-defaults BEFORE this bridge, so the path is set here.
IB_PY="$REPLAY_ROOT/agents/issue_body.py"
