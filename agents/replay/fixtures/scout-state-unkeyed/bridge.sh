# ── bridge ── unkeyed S3 state: both read and write fail with empty credentials.
#
# The seams block (composed just above this one) has already defined `scout_catalog`,
# `scout_state_read` and `scout_state_write` in their REAL form. This file redefines all three:
# `scout_catalog` serves a recorded world; `scout_state_read` FAILS (returning non-zero, which the
# shipped code handles as "no snapshot yet" = bootstrap tick); `scout_state_write` ALSO FAILS, but
# the shipped code now guards it with `|| log "scout: bootstrap snapshot write failed (non-fatal)"`
# so the tick survives instead of dying with `set -e` exit code 1.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CEILING="0.50"
STATE="s3://agent-transcripts/_model-scout/known-models.json"

# The clock, and only the clock: shipped `log` stamps every line with `date -u +%H:%M:%S`, which
# would make this fixture red once per second.
log() { printf '%s\n' "$*"; }

# Recorded reads, each announced as a CALL.
scout_catalog() {
  printf 'CALL curl GET https://openrouter.ai/api/v1/models\n' >> "$REPLAY_ACTIONS"
  cat "$REPLAY_FIXTURE/world/openrouter/models.json"
}

# Both state functions FAIL — simulating empty/optional credentials.
scout_state_read() {
  printf 'CALL s5cmd cp s3://agent-transcripts/_model-scout/known-models.json (snapshot read) — FAIL\n' >> "$REPLAY_ACTIONS"
  return 1
}

scout_state_write() {
  printf 'CALL s5cmd cp %s s3://agent-transcripts/_model-scout/known-models.json (%s ids) — FAIL\n' \
    "$(basename "$1")" "$(jq length "$1")" >> "$REPLAY_ACTIONS"
  return 1
}