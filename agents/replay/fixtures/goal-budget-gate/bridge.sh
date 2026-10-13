# ── bridge ── the launcher variables the gate block reads, and nothing else. Every name here is an
# agent-session.sh variable the dispatch site sets (`ORG`, `PROJECT`, `GOAL_PARENT`, `MODEL`,
# `ISSUE_N`), never a harness invention — a bridge that renames things is a bridge that pins a
# different clause. GOAL_PARENT is each row's ENTRY POINT into the tree, pinned in the rows.psv env
# column; the others are constant across the fleet.
ORG=teststuffstash
PROJECT=homelab
GOAL_PARENT="${GOAL_PARENT:?this row must pin its goal: env GOAL_PARENT=<n>}"
MODEL=opencode-go/deepseek-v4-flash
ISSUE_N=509

# The REAL helpers, SOURCED from the checkout — never transcribed (#166: a transcribed copy goes
# green while the original drifts). goal-budget.sh for the arithmetic; machine-comment.sh for the
# refusal's find-or-create, exactly as agent-session.sh sources both. goal-budget.sh's two I/O
# seams, and ONLY those, are redefined so the whole arithmetic runs against the recorded world:
#   gb_ledger  the pushgateway scrape → this fixture's recording (absent file = unreachable ledger,
#              which is the conservative cap-sum path the helper documents)
#   gb_cap     the estimator → a fixed cap. estimate_budget.py prices against a LIVE OpenRouter
#              registry; a price move must not red a fixture that pins the gate's branching.
#
# TWO SHAPES of ledger recording, because the seam sits on either side of the parser:
#   ledger.txt               the PARSED ledger (`<project> <issue> <usd>` lines) — gb_ledger is
#                            replaced whole, the real awk never runs. Enough for the gate's
#                            branching, blind to the parser: retro r8 F2 (a subscription ride
#                            priced at full cap) lived entirely inside that awk and no row here
#                            could have caught it.
#   pushgateway-metrics.txt  the RAW `/metrics` scrape, in the exposition shape agent-finalize
#                            pushes (agent-runtime agent-base/agent-finalize `push_metrics`).
#                            Only the GET is stubbed — `curl` becomes a function that prints the
#                            recording (gb_ledger's command substitution inherits it) — and the
#                            SHIPPED gb_ledger parses it. A row that needs the parser's verdict
#                            records this shape; it takes precedence over ledger.txt.
. "$REPLAY_ROOT/agents/goal-budget.sh"
. "$REPLAY_ROOT/agents/machine-comment.sh"

if [ -f "$REPLAY_WORLD/pushgateway-metrics.txt" ]; then
  curl() { cat "$REPLAY_WORLD/pushgateway-metrics.txt"; }
else
  gb_ledger() { if [ -f "$REPLAY_WORLD/ledger.txt" ]; then cat "$REPLAY_WORLD/ledger.txt"; fi; }
fi
gb_cap()    { echo "2.0000"; }
