#!/usr/bin/env bash
# recording stub — the dispatch handoff IS the assertion on this leg (the unit flowed through)
printf "CALL coordinator-session %s\n" "$*" >> "$REPLAY_ACTIONS"
exit 0
