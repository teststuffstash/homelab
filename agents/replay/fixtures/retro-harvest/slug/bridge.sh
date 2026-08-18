# ── bridge ── the six variables retro-argo.yaml's harvest step sets above the block: the run
# coordinates (DATE from `date +%F`, STACK and the next rN, all resolved before the block so the
# fixture is not dated by the clock) and the two cell→log pairs, straight off the workflow params.
DATE="2026-08-11"
STACK="oracle"
RUN="r3"
LOG_A="$PWD/log-a"; CELL_A="claude:opus"
LOG_B="$PWD/log-b"; CELL_B="goose:deepseek/deepseek-v4-pro"

# The seam. `cp` is the clause's only mutation and its whole output is the destination PATH, so it
# is recorded in the same vocabulary as any other action instead of writing into the checkout —
# the responder fixtures' `curl` pattern (agents/replay/README.md §When the clause lives inside a
# manifest). The SOURCE stays real: /tmp/report.md is what the extraction above it just wrote.
cp() { printf 'CALL cp %s\n' "$*" >> "$REPLAY_ACTIONS"; }
