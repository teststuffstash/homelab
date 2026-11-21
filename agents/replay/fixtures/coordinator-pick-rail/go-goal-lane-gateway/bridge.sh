#!/usr/bin/env bash
# Drive for coordinator-pick-rail-go-goal-lane-gateway: the REAL helpers (goal_lane_defers, dispatch_model)
# over two stacks — platform (gateway admission) and oracle (old proxy) — on a Go pick.
HERE="$REPLAY_FIXTURE"

echo "REACHED: ladder"
RAIL="$(coordinator_rail)"
echo "rail=${RAIL}"
for stack in platform oracle; do
  for clause in goal-decompose goal-checkpoint queued-dispatch; do
    if goal_lane_defers "$clause" "$RAIL" "$stack"; then
      echo "stack=${stack} clause=${clause} → DEFER"
    else
      echo "stack=${stack} clause=${clause} → dispatch model=$(dispatch_model "$clause" "$RAIL" "$stack" sonnet)"
    fi
  done
done
echo "REACHED: end"
