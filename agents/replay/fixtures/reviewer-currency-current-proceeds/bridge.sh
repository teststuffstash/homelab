# ── bridge — seams only, no gate logic. Function-shadow `gh` so the fixture controls the EXACT
# payload the currency gate parses (its contract is what the launcher does with the JSON, not how
# the real gh serves it). Records the CALL line in the action stream — same shape as the replay
# PATH-shim's `_rp_record` — then serves the fixture's world recording, falling back inline.
HERE="$REPLAY_FIXTURE"
PROJECT="${PROJECT:-test-project}"
PR="${PR:-42}"
REPO_SLUG="${REPO_SLUG:-teststuffstash/test-project}"

gh() {
  {
    printf 'CALL gh'
    for _a in "$@"; do
      printf ' %s' "$_a"
    done
    printf '\n'
  } >> "$REPLAY_ACTIONS"
  if [ -f "$REPLAY_WORLD/gh/pr-view-42.json" ]; then
    cat "$REPLAY_WORLD/gh/pr-view-42.json"
    return 0
  fi
  if [ -f "$REPLAY_WORLD/gh/pr-view-42.txt" ]; then
    cat "$REPLAY_WORLD/gh/pr-view-42.txt"
    return 0
  fi
  printf '{"headRefOid":"abc1234def","state":"OPEN","mergeStateStatus":"CLEAN"}'
  return 0
}
