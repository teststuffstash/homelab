# ── bridge ── everything model-scout.sh sets up before its diff clause, and nothing else.
#
# The seams block (composed just above this one, straight out of the shipped script) has already
# defined `scout_catalog`, `scout_state_read` and `scout_state_write` in their REAL form; this file
# redefines exactly those three — the tick's only network/S3 touches — and leaves the base-id
# arithmetic, the `:batch` rule and the candidate filter to the shipped code. That is the round the
# harness requires (agents/replay/README.md §When a clause depends on a sourced helper): stub the
# I/O, never the branching.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CEILING="0.50"

# The clock, and only the clock: shipped `log` stamps every line with `date -u +%H:%M:%S`, which
# would make this fixture red once per second. Same treatment `mc_now` gets.
log() { printf '%s\n' "$*"; }

# Recorded reads, each announced as a CALL — an unrecorded probe and a probe that stopped happening
# look identical in an action stream unless the read itself is in it (README, fix-debounce note).
scout_catalog() {
  printf 'CALL curl GET https://openrouter.ai/api/v1/models\n' >> "$REPLAY_ACTIONS"
  cat "$REPLAY_FIXTURE/world/openrouter/models.json"
}
scout_state_read() {
  printf 'CALL s5cmd cp s3://agent-transcripts/_model-scout/known-models.json (snapshot read)\n' >> "$REPLAY_ACTIONS"
  cat "$REPLAY_FIXTURE/world/s3/known-models.json" > "$1"
}
scout_state_write() {
  printf 'CALL s5cmd cp %s s3://agent-transcripts/_model-scout/known-models.json (%s ids)\n' \
    "$(basename "$1")" "$(jq length "$1")" >> "$REPLAY_ACTIONS"
}
