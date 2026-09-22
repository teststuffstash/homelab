#!/usr/bin/env bash
# Drive for coordinator-pick-rail (homelab#439 leg 3): the COORDINATOR lane's rail ladder.
# The helpers live in the config-defaults block (run.sh prepends it to every composition sourced
# from coordinator-scan.sh), so this bridge only supplies the seam and exercises them.
#
# HERE anchors coordinator_rail's `bash "${HERE}/subscription-latch.sh" --pick-rail` at the
# per-arm stub beside this file — the same seam every other scan fixture uses.
HERE="$REPLAY_FIXTURE"

echo "REACHED: ladder"
if RAIL="$(coordinator_rail)"; then
  echo "rail=${RAIL}"
  # `sonnet` stands in for the stack's coordinatorModel: a Go pick REPLACES it, "anthropic" does not.
  echo "model=$(rail_model "$RAIL" sonnet)"
  case "$RAIL" in opencode-go/*) echo "  capacity: Anthropic latched — this pass dispatches on the Go rail (${RAIL})";; esac
else
  echo "  capacity: BOTH rails limited (FU-088) — no dispatch this pass (level-triggered; next scan re-checks)."
fi
echo "REACHED: end"
