# ── bridge ── shared across all retro-quiet-guard rows (homelab#2932).
#
# The guard block reads STACK (fixture.yaml env) and WORK (the manifest sets WORK=/work just
# above the block; here it is a tmpdir, so the block's output writes stay out of the fixture).
#
# Seams, the retro-push-belt bridge's shapes:
#   python3 — record the call (WORK scrubbed to the literal `$WORK`), exit PREP_RC
#   curl    — record the call, consume stdin, CURL_RC_1 on first call, CURL_RC_2 after
#             (file counter: each pipe stage is its own subshell)
#   date    — fixed DATE_TS; `$(date +%s)` runs in a subshell, so it is NOT recorded
#   sleep   — a no-op (the retry's 3 s backoff asserts nothing)
#
# Observation point: an EXIT trap, because every non-fall-through branch of the block `exit`s
# before any post part could run. It prints the `quiet` output parameter and the bundle body.

STACK="${STACK:?fixture must pin STACK}"
WORK="$(mktemp -d)"

python3() {
  local a="$*"
  printf 'CALL python3 %s\n' "${a//$WORK/\$WORK}" >> "$REPLAY_ACTIONS"
  return "${PREP_RC:?row must pin PREP_RC}"
}

__curl_count_file="$REPLAY_ACTIONS.curl_count"
curl() {
  local count=0
  [ -f "$__curl_count_file" ] && count=$(cat "$__curl_count_file")
  count=$((count + 1))
  printf '%d' "$count" > "$__curl_count_file"
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  cat > /dev/null
  if [ "$count" -eq 1 ]; then
    return "${CURL_RC_1:-0}"
  else
    return "${CURL_RC_2:-0}"
  fi
}

date() {
  if [ "$*" != "+%s" ]; then
    printf 'CALL date %s\n' "$*" >> "$REPLAY_ACTIONS"
  fi
  printf '%s' "${DATE_TS:?fixture must pin DATE_TS}"
}

sleep() { :; }

__observe() {
  echo "QUIET: $(cat "$WORK/quiet" 2>/dev/null || echo '<unset>')"
  echo "BUNDLE: $(cat "$WORK/bundle.json" 2>/dev/null || echo '<none>')"
  rm -rf "$WORK"
}
trap __observe EXIT
