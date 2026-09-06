# Observe the PROMPT mutations after calling depth-rule-append for each of the four rows.
# Row (a): goal-base depth 2 → suppressed
PROMPT="Initial prompt."
depth-rule-append 2 "goal/s6" "" "" 1 "$REPO_SLUG" && _rc=0 || _rc=$?
if printf '%s' "$PROMPT" | grep -q "DO NOT emit a Follow-ups: section"; then
  echo "OUT row_a=suppress" >> "$REPLAY_ACTIONS"
elif [ "$_rc" = "1" ]; then
  echo "OUT row_a=none" >> "$REPLAY_ACTIONS"
fi

# Row (b): master-base depth 2 → allowed (no rule appended, depth < 4 on organic lane)
PROMPT="Initial prompt."
depth-rule-append 2 "master" "" "" 1 "$REPO_SLUG" && _rc=0 || _rc=$?
if [ "$_rc" = "1" ]; then
  echo "OUT row_b=none" >> "$REPLAY_ACTIONS"
fi

# Row (c): master-base depth 4 non-hotfix → Container-findings
PROMPT="Initial prompt."
depth-rule-append 4 "master" "some title" "" 1 "$REPO_SLUG" && _rc=0 || _rc=$?
if printf '%s' "$PROMPT" | grep -q "Container-findings"; then
  echo "OUT row_c=container-findings" >> "$REPLAY_ACTIONS"
elif [ "$_rc" = "1" ]; then
  echo "OUT row_c=none" >> "$REPLAY_ACTIONS"
fi

# Row (d): master-base depth 4 + line-anchored alert-fp: body → Follow-ups (no rule appended)
PROMPT="Initial prompt."
depth-rule-append 4 "master" "some title" "alert-fp: true" 1 "$REPO_SLUG" && _rc=0 || _rc=$?
if [ "$_rc" = "1" ]; then
  echo "OUT row_d=none" >> "$REPLAY_ACTIONS"
fi

# Row (e): master-base depth 4 + MALFORMED machine block → NO SIGNAL: no rule appended (the
# Follow-ups channel stays open), one WARN on stderr. Pins the PR#1459 review finding: an
# unreadable body must not read as "not hotfix" and narrow the review to Container-findings.
PROMPT="Initial prompt."
depth-rule-append 4 "master" "some title" "$(printf -- '---\nalert-fp: abc\nbogus line\n---\nbody')" 1 "$REPO_SLUG" && _rc=0 || _rc=$?
if printf '%s' "$PROMPT" | grep -q "Container-findings"; then
  echo "OUT row_e=container-findings" >> "$REPLAY_ACTIONS"
elif [ "$_rc" = "1" ]; then
  echo "OUT row_e=none" >> "$REPLAY_ACTIONS"
fi

printf 'OUT depth_lane_split_executed=1\n' >> "$REPLAY_ACTIONS"
