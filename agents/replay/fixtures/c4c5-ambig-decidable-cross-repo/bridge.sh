# ── bridge ── the per-repo loop variables the C4/C5 clause already holds by the time the
# ambig-decidable check runs. Every name is a SCAN name (`slug`, `repo`, `inprog`, `BODIES`,
# `c6g_nums`, `goalbased_nums`, `dispatchable`, `c4c5_cleared`, `orphans`, `units`) — a bridge that
# invents one pins a different clause.
#
# This fixture runs the bridge TWICE (once per repo) to simulate a multi-repo stack tick.
# The first run sets up repo A (homelab), the second sets up repo B (oracle-fleet).
# Accumulated variables (orphans, units, resumable_branches) persist between runs.
#
# `inprog` and `BODIES` arrive as recorded files rather than stubbed calls because the enclosing
# loop fetches both far above the block under replay.
#
# `goalbased_nums` includes #329 for repo A (a goal child) but not for repo B (plain in-progress).
CROSS_REPO_PASS="${CROSS_REPO_PASS:-0}"
case "${CROSS_REPO_PASS}" in
  0)
    # First pass: repo A (homelab) — issue #329 is a goal child with strike+resumable
    slug="teststuffstash/homelab"
    repo="homelab"
    dispatchable=1
    c6g_nums=""
    goalbased_nums="329"
    c4c5_cleared=""
    orphans="${orphans:-}"
    units="${units:-}"
    resumable_branches="${resumable_branches:-}"
    BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies-homelab.json")"
    inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog-homelab.json")"
    ;;
  1)
    # Second pass: repo B (oracle-fleet) — issue #329 is a plain in-progress issue (NOT goal child)
    # Save v2 from pass 0 before the second block overwrites it
    v2_pass0="${v2:-}"
    slug="teststuffstash/oracle-fleet"
    repo="oracle-fleet"
    dispatchable=1
    c6g_nums=""
    goalbased_nums="329"
    c4c5_cleared=""
    # orphans, units, resumable_branches persist from the first pass
    BODIES="$(cat "$REPLAY_WORLD/gh/pr-list-bodies-oracle-fleet.json")"
    inprog="$(cat "$REPLAY_WORLD/gh/issue-list-inprog-oracle-fleet.json")"
    ;;
  2)
    # Third pass: resumable match for repo A (homelab) — both repos' resumable_branches are
    # now populated from the two c4c5-derivations runs. Run the match logic for homelab #329.
    slug="teststuffstash/homelab"
    repo="homelab"
    uclause="c4c5-redispatch"
    urepo="homelab"
    uitem="issue-329"
    ;;
  3)
    # Fourth pass: resumable match for repo B (oracle-fleet) — run the match logic for
    # oracle-fleet #329, which should resolve to its own branch (not homelab's).
    slug="teststuffstash/oracle-fleet"
    repo="oracle-fleet"
    uclause="c4c5-redispatch"
    urepo="oracle-fleet"
    uitem="issue-329"
    ;;
esac
CROSS_REPO_PASS=$((CROSS_REPO_PASS + 1))
# ── stub ── the scan accumulates rows during a pass and flushes one POST per (tick, namespace),
# so a harness running one extracted block has no flush to assert on.
item_class_push() { :; }