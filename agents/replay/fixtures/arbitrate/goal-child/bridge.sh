# ── bridge ── the per-stack loop variables the harvest-disposition block reads. Every name here
# is a SCAN variable the dispatch site sets (`ORG`, `urepo`, `uclause`, `uitem`, `wmodel`, `HERE`),
# never a harness invention — a bridge that renames things is a bridge that pins a different clause.
ORG="$IN_ORG"
urepo="$IN_REPO"
uclause="$IN_CLAUSE"
uitem="$IN_ITEM"
wmodel="$IN_WMODEL"
HERE="$REPLAY_ROOT/agents"

# The REAL budget helper, SOURCED from the checkout — never transcribed, for the same reason the
# clause itself is sentinel-extracted (#166: a transcribed copy goes green while the original
# drifts). The block itself sources it too; `command -v` there makes this pre-source a no-op.
. "$REPLAY_ROOT/agents/goal-budget.sh"

# Its two I/O seams, and ONLY those, are redefined — the descendant walk, the per-child charge
# rules, the fallbacks and the comparison all run for real against the recorded world:
#   gb_ledger  the pushgateway scrape → this fixture's recording (absent file = unreachable
#              ledger, which is the conservative cap-sum path the helper documents)
#   gb_cap     the estimator → a fixed cap. estimate_budget.py prices against a LIVE OpenRouter
#              registry; a price move must not red a fixture that pins HARVEST behaviour.
gb_ledger() { if [ -f "$REPLAY_WORLD/ledger.txt" ]; then cat "$REPLAY_WORLD/ledger.txt"; fi; }
gb_cap()    { echo "$IN_CAP"; }