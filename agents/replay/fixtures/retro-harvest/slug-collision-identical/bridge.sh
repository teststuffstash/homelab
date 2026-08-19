# ── bridge ── the six variables retro-argo.yaml's harvest step sets above the block: the run
# coordinates (DATE from `date +%F`, STACK and the next rN, all resolved before the block so the
# fixture is not dated by the clock) and the two cell→log pairs, straight off the workflow params.
#
# What differs from `retro-harvest-slug-collision`: the two cells are the SAME harness AND the
# SAME model — a pure A/B repeat (e.g. re-running "claude:opus" twice to sample variance on one
# cell), the shape pass 2's own harness join cannot separate: "claude:opus" joined with its own
# harness is "claude-opus" on BOTH legs, still equal, and the second `cp` overwrote the first —
# homelab#292, one layer under the bug pass 2 fixed.
DATE="2026-08-11"
STACK="oracle"
RUN="r3"
LOG_A="$PWD/log-a"; CELL_A="claude:opus"
LOG_B="$PWD/log-b"; CELL_B="claude:opus"

# The block now calls `bash agents/retro-report-floor.sh` at the relative path the real script
# resolves it at (cwd = /work/homelab). Stage the REAL helper at that same relative path under a
# throwaway dir — never the committed fixture dir (the `scout-bench` $WORK pattern) — then `cd`
# there, AFTER every $PWD-relative variable above is already resolved and BEFORE `cp` is shadowed
# below (this staging copy must be the real binary, not the seam). Extraction-never-transcription:
# the floor logic is never copied into a fixture, only the shipped file, verbatim.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/agents"
cp "$REPLAY_ROOT/agents/retro-report-floor.sh" "$WORK/agents/retro-report-floor.sh"
cd "$WORK"

# The seam. `cp` is the clause's only mutation and its whole output is the destination PATH, so it
# is recorded in the same vocabulary as any other action instead of writing into the checkout —
# the responder fixtures' `curl` pattern (agents/replay/README.md §When the clause lives inside a
# manifest). The SOURCE stays real: /tmp/report.md is what the extraction above it just wrote.
cp() { printf 'CALL cp %s\n' "$*" >> "$REPLAY_ACTIONS"; }
