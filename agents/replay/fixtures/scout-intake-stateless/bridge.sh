# ── bridge ── operator intake: catalog recorded; the STATE seams are tripwires — the intake
# contract is that neither is ever invoked, so each records a CALL that would red the stream.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
CEILING="0.50"
STATE="s3://agent-transcripts/_model-scout/known-models.json"
log() { printf '%s\n' "$*"; }
scout_catalog() {
  printf 'CALL curl GET https://openrouter.ai/api/v1/models\n' >> "$REPLAY_ACTIONS"
  cat "$REPLAY_FIXTURE/world/openrouter/models.json"
}
scout_state_read()  { printf 'CALL scout_state_read (MUST NOT HAPPEN in intake mode)\n'  >> "$REPLAY_ACTIONS"; return 1; }
scout_state_write() { printf 'CALL scout_state_write (MUST NOT HAPPEN in intake mode)\n' >> "$REPLAY_ACTIONS"; return 1; }
