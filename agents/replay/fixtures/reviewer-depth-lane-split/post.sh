# Observe the PROMPT mutations and HOTFIX flag after block execution
printf 'OUT depth_lane_split_executed=1\n' >> "$REPLAY_ACTIONS"

if printf '%s' "$PROMPT" | grep -q "DEPTH RULE"; then
  if printf '%s' "$PROMPT" | grep -q "DO NOT emit a Follow-ups: section"; then
    echo "OUT depth_rule_mode=suppress" >> "$REPLAY_ACTIONS"
  elif printf '%s' "$PROMPT" | grep -q "Container-findings"; then
    echo "OUT depth_rule_mode=container-findings" >> "$REPLAY_ACTIONS"
  fi
else
  echo "OUT depth_rule_mode=none" >> "$REPLAY_ACTIONS"
fi
