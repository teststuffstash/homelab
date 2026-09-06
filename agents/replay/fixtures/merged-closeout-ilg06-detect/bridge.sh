# ── bridge ── the per-repo loop variables the C6 merged-closeout clause holds by the time the
# block runs. Every name is a SCAN name (`slug`, `repo`, `default_branch`, `c6g`, `c6g_nums`,
# `c6db`, `c6db_nums`, `units`, `items`, `orphans`, `dispatchable`) — a bridge that invents one
# pins a different clause.
#
# This fixture tests the POSITIVE-PATH detection semantics of the IL-G06 block:
#   - #90: merged PR #200 has `Fixes #90` (strong link) BUT open PR #300 mentions #90 → dref > 0 → NOT detected
#   - #91: merged PR #201 has `Implements #91` (strong link) AND no open PR mentions #91 → dref = 0 → DETECTED
#   - #92: merged PR #202 has `Related to #92` (bare mention, not strong link) → dhit = 0 → orphan message
#   - #93: merged PR #203 `Implements #93`, no open PR — BUT the issue's newest agent/in-progress
#          labeled event (07:03:59Z) post-dates the merge (06:40:31Z): the closeout for that merge
#          was already spent (re-queued + re-claimed, the oracle-fleet#397 r6 shape) → HELD with a
#          report line, no unit (homelab#1472). Events world: issues-93-events.json.
#   - #94: merged PR? none strong-links #94 (dhit = 0, dmention = 0) → silent; its events world
#          exists so a regression that probes events BEFORE the strong-link test shows up as a CALL.
#
# The state-keyed world files (pr-list-merged, pr-list-open) are served distinctly by the stub
# after homelab#1199 fixed _rp_words to keep --state values in the world key.
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
# goalcand: three open issues with agent/fix + (agent/in-progress|agent/review),
# no agent/error, and no Base: line — all are candidates for IL-G06 detection.
goalcand='[
  {"number": 90, "title": "test issue 90", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/in-progress"}]},
  {"number": 91, "title": "test issue 91", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/review"}]},
  {"number": 92, "title": "test issue 92", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/in-progress"}]},
  {"number": 93, "title": "test issue 93", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/in-progress"}]},
  {"number": 94, "title": "test issue 94", "body": "", "labels": [{"name": "agent/fix"}, {"name": "agent/review"}]}
]'
# dbmerged and dbopen are fetched by the IL-G06 detection block from the replay world.
# world/gh/pr-list-merged.json has the merged PRs (state-keyed).
# world/gh/pr-list-open.json has the open PR bodies (state-keyed).
# The detection block will derive c6db and c6db_nums from the fetched data.
ISSUE_LIST_LIMIT=200

# Stub for item_class_push — the real function is defined in the scan's outer scope and not
# available in the extracted block. This stub just records the call for the action stream.
item_class_push() {
  local repo="${1:?}" item="${2:?}" class="${3:?}" who="${4:?}"
  echo "item_class_push: $repo $item $class $who" >&2
}