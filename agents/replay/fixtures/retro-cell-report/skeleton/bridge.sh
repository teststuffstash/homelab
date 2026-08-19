# ── bridge ── same two retro-cell variables as its siblings, pointing at a log that carries the
# BEGIN/END markers but only the report TEMPLATE's bare section headings between them — the exact
# shape of the 2026-08-17 unattended fire's deepseek cell (docs/agents/retros/2026-08-17-oracle-r4-
# deepseek-v4-pro.md, 9 lines, all headings). `-s` passed on this shape before homelab#590; the
# floor is the fix.
RIDE_LOG="$PWD/ride.log"
CELL="goose:deepseek/deepseek-v4-pro"

# The block now calls `bash agents/retro-report-floor.sh` at the relative path the real script
# resolves it at (cwd = /work/homelab after the `cd` above it). Stage the REAL helper at that same
# relative path, under a throwaway dir — never the committed fixture dir itself (the `scout-bench`
# $WORK pattern) — then `cd` there so the block's relative path resolves. Extraction-never-
# transcription: the floor logic is never copied into a fixture, only the shipped file, verbatim.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/agents"
cp "$REPLAY_ROOT/agents/retro-report-floor.sh" "$WORK/agents/retro-report-floor.sh"
cd "$WORK"
