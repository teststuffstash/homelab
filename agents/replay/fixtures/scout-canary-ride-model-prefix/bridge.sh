# ── bridge ── call `scout_canary_ride` and assert the full provider-prefixed model ID is composed.
#
# The `scout-seams` block (composed just above) defines `scout_canary_ride` in its REAL form.
# This bridge shadows the bash() call (which invokes agent-session.sh in the real flow) to record
# the composed command without actually executing it.
#
# The fix changes the --run argument from using the stripped pod-env $MODEL to the full launcher-side
# composed id "openrouter/$id". This fixture pins that the recorded bash invocation contains the
# full provider-prefixed ID in the -m argument.

bash() {
  printf 'CALL bash %s\n' "$*" >> "$REPLAY_ACTIONS"
}

CANARY_PROJECT="teststuffstash"
HERE="/replay/agents"

# Call scout_canary_ride with deepseek/deepseek-v4-flash (the test model from the issue evidence).
# The stub records the agent-session.sh invocation (the bash call above).
# After the fix, the recorded command will show `-m "openrouter/deepseek/deepseek-v4-flash"`.
scout_canary_ride "deepseek/deepseek-v4-flash" "false"
