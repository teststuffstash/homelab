# ── bridge ── two halves, because an ERRORED cell is half declaration and half consequence.
#
# HALF 1: the DAG edge. Argo assigns the Error phase (OOMKilled, evicted, node lost) — the harness
# cannot produce one, and no shell clause reads `continueOn`, so the thing this fixture can honestly
# assert about the phase is the DECLARATION that covers it. Read out of the shipped manifest, never
# transcribed (agents/replay/README.md — a copy goes green while the original moves): if either cell
# loses `error: true`, or the widening is reverted, this line moves and the fixture reds. The
# consequence replay below would NOT have caught that on its own.
awk '
  /^ *- name: cell-[ab]$/ { task = $3; next }
  task && /^ *continueOn:/ {
    printf "dag %s continueOn: failed=%s error=%s\n", task,
           ($0 ~ /failed: true/ ? "true" : "false"), ($0 ~ /error: true/ ? "true" : "false")
    task = ""; next
  }
  task && /^ *- name: / { task = "" }   # a cell task that declared no continueOn at all: prints nothing
' "$REPLAY_ROOT/agents/coordinator/retro-argo.yaml"

# HALF 2: the harvest, with the world that edge lets it reach. Same six variables the harvest step
# sets above the block as `retro-harvest-one-cell-dead` — except LOG_B, which points at a path that
# DOES NOT EXIST: an errored pod dies before `tee` ever creates /work/ride.log, so the output
# artifact is never written, `{{tasks.cell-b.outputs.artifacts.ride-log}}` resolves to nothing, and
# `optional: true` means Argo stages no file into the harvest at all. Not "a log with no markers"
# (the sibling fixture's world) — no log.
DATE="2026-08-11"
STACK="oracle"
RUN="r4"
LOG_A="$PWD/log-a"; CELL_A="claude:opus"
LOG_B="$PWD/log-b-never-written"; CELL_B="goose:deepseek/deepseek-v4-pro"

# The seam, verbatim from the sibling: `cp` is the clause's only mutation and its whole output is
# the destination PATH, so it is recorded as an action instead of writing into the checkout.
cp() { printf 'CALL cp %s\n' "$*" >> "$REPLAY_ACTIONS"; }
