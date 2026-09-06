# ── bridge ── the one variable the preflight-body-parser block reads.
# `HERE` must be the REAL agents/ directory: this fixture drives the ACTUAL parser over the actual
# bodies, never a restatement of it (a stub would test the stub).
HERE="$(cd "$REPLAY_FIXTURE/../../../.." && pwd)/agents"
