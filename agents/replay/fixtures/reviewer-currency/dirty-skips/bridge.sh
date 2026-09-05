# ── bridge — seams only, no gate logic. Function-shadow `gh` so the fixture controls the EXACT
# payload the currency gate parses (its contract is what the launcher does with the JSON, not how
# the real gh serves it). The CALL line is written STRAIGHT to the action file — never to stdout:
# the block runs `PR_JSON="$(gh …)"`, so anything on stdout becomes part of the parsed payload
# (the go-failover curl bridges have the same shape: file for the CALL, stdout for the payload).
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
  printf '{"headRefOid":"abc1234def","state":"OPEN","mergeStateStatus":"DIRTY"}'
  return 0
}
