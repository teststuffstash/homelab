# ── bridge ── same two retro-cell variables as its siblings, pointing at a log that carries
# FOUR BEGIN/END-RETRO-REPORT pairs — three empty skeletons and one real report — plus inter-block
# harness text glued to the third END marker. The fix must extract only the LAST complete block.
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