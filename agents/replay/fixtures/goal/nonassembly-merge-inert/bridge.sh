# ── bridge ── the per-stack loop variables the goal-lane block reads. Every name here is a SCAN
# variable set earlier in the per-repo loop (`slug`, `repo`, `openall`, `orphans`, `units`), never
# a harness invention — a bridge that renames things is a bridge that pins a different clause.
#
# `openall` is the ONE open-issue fetch the whole per-repo loop derives from (coordinator-scan.sh
# §"ONE fetch, two derivations"). It is read far above the sentinel, so it arrives as a fixture
# file rather than a stub recording — the honest split: what the block CALLS is recorded under
# world/gh/, what it INHERITS is set here.
# The REAL findings-store helpers, SOURCED from the checkout (extraction-never-transcription —
# the goal-ancestor family's goal-budget.sh precedent): production's scan sources them at top;
# the extracted block gets them here. Every read/write they make rides the PATH-shim gh.
. "$REPLAY_ROOT/agents/goal-findings.sh"
slug="$IN_SLUG"
repo="$IN_REPO"
openall="$(cat "$REPLAY_FIXTURE/world/openall.json")"
orphans=""
units=""
