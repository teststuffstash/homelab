# ── bridge ── the launcher variables the goal-ancestor block reads, and nothing else. Every name
# here is an agent-session.sh variable the dispatch site sets (`ORG`, `PROJECT`, `ISSUE_N`), never
# a harness invention — a bridge that renames things is a bridge that pins a different clause.
ORG=teststuffstash
PROJECT=circles
ISSUE_N=90

# The REAL walk, SOURCED from the checkout — never transcribed (#166: a transcribed copy goes green
# while the original drifts). NO seam is redefined and none exists to redefine: `goal_resolve_
# ancestor` is pure shell over `gh`, so every read goes through the PATH-shim stub and the hop
# sequence itself lands in the asserted action stream. That is the whole point of this fixture —
# the defect was WHICH issues got read, not what was computed from them.
. "$REPLAY_ROOT/agents/goal-budget.sh"
