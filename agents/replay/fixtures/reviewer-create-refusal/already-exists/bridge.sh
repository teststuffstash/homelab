# ── bridge ── the three names the refusal reads, as a flagless dispatch leaves them: the pod the
# create was for, the namespace it was pointed at (the default), and the file holding the create's
# stderr. The stderr is a COPY of the recorded world file — the refusal deletes CREATE_ERR, and the
# recorded world is read-only to a run.
POD="reviewer-snore-recorder-37-d19389f4"
NS="agent-coordinator"
CREATE_ERR="$(mktemp)"
cp "$REPLAY_WORLD/create-stderr.txt" "$CREATE_ERR"
