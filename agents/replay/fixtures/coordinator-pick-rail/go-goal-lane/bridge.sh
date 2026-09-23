#!/usr/bin/env bash
# Drive for coordinator-pick-rail-go-goal-lane (homelab#439 leg 3): the Go rail is clear, but the
# unit's clause is GOAL-LANE — `model-classes.json` → classes.goal-decompose pins claude/fable for
# a recorded reason (the design-agents corpus read), so the substitution must be refused and the
# unit deferred on capacity instead.
#
# Caught live 2026-09-18: the first latched tick after the ladder landed put a flash model on the
# decompose of Goal #1769, minutes after it was filed. This row is why the arm exists.
HERE="$REPLAY_FIXTURE"

echo "REACHED: ladder"
RAIL="$(coordinator_rail)"
echo "rail=${RAIL}"
for clause in goal-decompose goal-checkpoint changes-requested queued-dispatch; do
  if goal_lane_clause "$clause"; then
    echo "clause=${clause} → DEFER (class pins claude/fable; no Go substitution)"
  else
    echo "clause=${clause} → dispatch model=$(rail_model "$RAIL" sonnet)"
  fi
done
echo "REACHED: end"
