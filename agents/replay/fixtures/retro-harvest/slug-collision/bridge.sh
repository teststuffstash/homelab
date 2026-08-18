# ── bridge ── the six variables retro-argo.yaml's harvest step sets above the block: the run
# coordinates (DATE from `date +%F`, STACK and the next rN, all resolved before the block so the
# fixture is not dated by the clock) and the two cell→log pairs, straight off the workflow params.
#
# The ONLY thing that differs from `retro-harvest-slug`: the two cells name the SAME model under
# DIFFERENT harnesses, which is the dispatch a harness comparison run actually uses. The bare
# derivation ("claude:opus" → opus, "goose:opus" → opus) hands both legs one filename, so the
# second `cp` overwrote the first and the run shipped a "pair" that was one report — silently, the
# same failure class homelab#248 closed one layer earlier.
DATE="2026-08-11"
STACK="oracle"
RUN="r3"
LOG_A="$PWD/log-a"; CELL_A="claude:opus"
LOG_B="$PWD/log-b"; CELL_B="goose:opus"

# The seam. `cp` is the clause's only mutation and its whole output is the destination PATH, so it
# is recorded in the same vocabulary as any other action instead of writing into the checkout —
# the responder fixtures' `curl` pattern (agents/replay/README.md §When the clause lives inside a
# manifest). The SOURCE stays real: /tmp/report.md is what the extraction above it just wrote.
cp() { printf 'CALL cp %s\n' "$*" >> "$REPLAY_ACTIONS"; }
