#!/usr/bin/env bash
# Bridge for reflex-tick-skip: stub subscription-latch.sh, log function.

HERE="$REPLAY_FIXTURE"
export HERE

log() {
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$REPLAY_ACTIONS"
}
export -f log 2>/dev/null || true
