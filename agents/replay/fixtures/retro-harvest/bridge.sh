# ── bridge ── shared across all five retro-harvest rows (table conversion, stint #661 batch 4;
# was five copied directories, each with this file byte-identical past the six variables below).
#
# HALF 1 (declaration, `cell-errored` ONLY, gated by `env: DECLARE_CONTINUEON=1`): Argo — not any
# shell — decides an OOMKilled pod is `Error`, and `continueOn` is the DAG field that says whether
# the sibling and the harvest survive it; no clause reads that field, so the only honest assertion
# is the DECLARATION, read out of the shipped manifest and never transcribed
# (agents/replay/README.md §When the clause lives inside a manifest). Every other row leaves this
# unset and the block prints nothing — reverting the widening reds only the row that pins it.
if [ "${DECLARE_CONTINUEON:-0}" = "1" ]; then
  awk '
    /^ *- name: cell-[ab]$/ { task = $3; next }
    task && /^ *continueOn:/ {
      printf "dag %s continueOn: failed=%s error=%s\n", task,
             ($0 ~ /failed: true/ ? "true" : "false"), ($0 ~ /error: true/ ? "true" : "false")
      task = ""; next
    }
    task && /^ *- name: / { task = "" }   # a cell task that declared no continueOn at all: prints nothing
  ' "$REPLAY_ROOT/agents/coordinator/retro-argo.yaml"
fi

# HALF 2 (harvest world): the six variables retro-argo.yaml's harvest step sets above the block —
# the run coordinates and the two cell→log pairs — now come off this row's `env:` column instead
# of being hardcoded per copied directory (family defaults in fixture.yaml cover the ordinary
# case; a row overrides only its delta). LOG_A/LOG_B resolve under the family's shared,
# COMMITTED `logs/` directory via $REPLAY_ROOT — deliberately NOT the table harness's per-row
# world materialization ($REPLAY_FIXTURE/world/…): the WARN line below embeds a cell's log PATH
# LITERALLY in its own text (agents/retro-report-floor.sh), and that path must be a fixed,
# deterministic location, not the per-row $TMP staging directory every other seam in this harness
# reads through. (Documented deviation, migration commit: the WARN line's path segment now reads
# `logs/<name>` rather than the pre-conversion `<row-dir>/log-b` — the WARN *reason* word and the
# *cell name*, the actual assertion, are unchanged.)
DATE="${DATE:?fixture must pin DATE}"
STACK="${STACK:?fixture must pin STACK}"
RUN="${RUN:?fixture must pin RUN}"
CELL_A="${CELL_A:?fixture must pin CELL_A}"
CELL_B="${CELL_B:?fixture must pin CELL_B}"
LOG_A="$REPLAY_ROOT/agents/replay/fixtures/retro-harvest/logs/${LOG_A_NAME:?fixture must pin LOG_A_NAME}"
LOG_B="$REPLAY_ROOT/agents/replay/fixtures/retro-harvest/logs/${LOG_B_NAME:?fixture must pin LOG_B_NAME}"

# The block now calls `bash agents/retro-report-floor.sh` at the relative path the real script
# resolves it at (cwd = /work/homelab). Stage the REAL helper at that same relative path under a
# throwaway dir — never the committed fixture dir (the `scout-bench` $WORK pattern) — then `cd`
# there, AFTER every path above is already resolved and BEFORE `cp` is shadowed below (this
# staging copy must be the real binary, not the seam). Extraction-never-transcription: the floor
# logic is never copied into a fixture, only the shipped file, verbatim.
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
