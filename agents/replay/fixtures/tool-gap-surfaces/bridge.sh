# ── bridge ── the reader's input: the janitor's brief. The SHIPPED brief is the default, so the
# fixed row reads the real file (editing the declaration moves the fixture); a row may point
# BRIEF_NAME at a world copy to exercise a declaration the shipped brief does not carry.
BRIEF="${REPLAY_ROOT}/agents/coordinator/README.md"
[ -n "${BRIEF_NAME:-}" ] && BRIEF="${REPLAY_WORLD}/${BRIEF_NAME}"
EMITTER="${REPLAY_ROOT}/agents/reviewer-session.sh"