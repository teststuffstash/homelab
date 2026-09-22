#!/usr/bin/env bash
# Recording stub for the dispatch handoff (`bash "${HERE}/coordinator-session.sh" …`). A leg that
# reaches it is a leg both holds let through — that is the assertion.
printf "CALL coordinator-session %s\n" "$*" >> "$REPLAY_ACTIONS"
exit 0
