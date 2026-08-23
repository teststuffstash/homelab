# Degrade leg 2 (PR#768 review — the blocking finding): a PRESENT but EMPTY file (truncated
# checkout, bad merge). Under the original `-r`-only guard this silently dropped the whole
# ground-rules block with zero signal; the `-s` half of the guard is what this pins.
# The file lives in the HARNESS temp dir (dirname of REPLAY_ACTIONS — auto-scrubbed to $TMP in
# the stream, auto-removed at exit): the clause runs with cwd = the fixture dir, so a ./-relative
# file would litter the repo tree (learned the hard way — a chmod-000 leftover broke git add).
GROUND_RULES_FILE="$(dirname "$REPLAY_ACTIONS")/gr-empty.md"
: > "$GROUND_RULES_FILE"
