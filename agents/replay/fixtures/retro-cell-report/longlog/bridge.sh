# ── bridge ── the two variables retro-argo.yaml's retro-cell sets immediately above the block:
# the ride-log path (also the template's output-artifact path) and the cell it was dispatched as.
# $PWD is the fixture directory — run.sh cds into it — so the committed log stands in for the one
# `tee` wrote in the pod.
RIDE_LOG="$PWD/ride.log"
CELL="claude:opus"

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
