#!/usr/bin/env bash
# Bridge for reflex-tick fixtures: stub subscription-latch.sh via HERE override.

# Override HERE to point to fixture-local stub
HERE="$REPLAY_FIXTURE"
export HERE

# log function to record to actions file (REPLAY_ACTIONS is set by harness)
log() {
  printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$REPLAY_ACTIONS"
}
export -f log 2>/dev/null || true
