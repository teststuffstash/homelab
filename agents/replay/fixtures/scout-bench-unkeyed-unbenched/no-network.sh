# The whole subject of this fixture is a call that must NOT happen, so the transport is replaced by
# a tripwire rather than by a recording: if the env gate ever leaks, the stream gains a CALL line
# AND the fixture dies at exit 9 — loud in two vocabularies. A shadow that quietly returned nothing
# would let the leg go green while a keyless production tick sat there talking to the internet.
curl() {
  printf 'CALL curl UNEXPECTED — the env gate leaked: %s\n' "$*" >> "$REPLAY_ACTIONS"
  exit 9
}
