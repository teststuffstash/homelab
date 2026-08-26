# ── bridge ── shared across all three retro-push-belt rows (FU-176 / #932).
#
# The push belt reads these variables set above it in the same step:
#   DATE, STACK, RUN — run coordinates (fixture.yaml defaults)
#   GH_TOKEN         — from the git secret (fixture.yaml default)
#   BR               — computed from DATE/STACK/RUN (fixture.yaml default)
#   DEAD_NOTE        — set earlier in the step (fixture.yaml default)
#
# Three seams, all following the established pattern:
#   curl — record the call, return CURL_RC_1 on first call, CURL_RC_2 on second
#          (modelled on fu088-ladder/bridge.sh and go-rail-latch/bridge.sh)
#   date — record the call, return a fixed timestamp (DATE_TS, modelled on
#          summary-comment/bridge.sh's mc_now seam)
#   git  — record the call (the push belt's git add/commit/push are inside the
#          PUSH_FAILED=1 branch; the git config/checkout/add/commit/push for the
#          PR creation are in retro-harvest-slug, above this block)
#
# `gh` is served by the harness's PATH stub (agents/replay/stubs/gh).
# `echo` and `printf` are real — echo's stdout is captured by the harness as OUT lines,
# and printf's output either pipes into curl (which is shadowed) or is captured in a
# command substitution (PUSH_WARN).

DATE="${DATE:?fixture must pin DATE}"
STACK="${STACK:?fixture must pin STACK}"
RUN="${RUN:?fixture must pin RUN}"
BR="${BR:?fixture must pin BR}"
GH_TOKEN="${GH_TOKEN:?fixture must pin GH_TOKEN}"
DEAD_NOTE="${DEAD_NOTE:-}"

# ── curl seam ──
# Count calls so CURL_RC_1 drives the first call and CURL_RC_2 drives the retry.
# A row that sets CURL_RC_1=0 never reaches the second call; a row that sets
# CURL_RC_1=1 CURL_RC_2=0 exercises the retry leg; CURL_RC_1=1 CURL_RC_2=1
# exercises the full failure surface.
#
# Uses a FILE-BASED counter because each pipe creates a new subshell and shell
# variables are not shared across subshells. The two pipelines run sequentially
# (the retry only starts after the first fails), so there is no race.
__curl_count_file="$REPLAY_ACTIONS.curl_count"
curl() {
  local count=0
  [ -f "$__curl_count_file" ] && count=$(cat "$__curl_count_file")
  count=$((count + 1))
  printf '%d' "$count" > "$__curl_count_file"
  printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
  # Consume stdin to prevent SIGPIPE when the caller pipes data via --data-binary @-
  # (the existing fu088-ladder and go-rail-latch shadows don't need this because they
  # never receive piped data; this belt's pushgateway push does.)
  cat > /dev/null
  if [ "$count" -eq 1 ]; then
    return "${CURL_RC_1:-0}"
  else
    return "${CURL_RC_2:-0}"
  fi
}

# ── date seam ──
# Return a fixed timestamp so the action stream is deterministic.
# Only record non-trivial calls (e.g. `date > file`). The `$(date +%s)` command
# substitution runs in a subshell whose write to REPLAY_ACTIONS interleaves
# non-deterministically with the pipe's curl call — so we skip recording it.
date() {
  if [ "$*" != "+%s" ]; then
    printf 'CALL date %s\n' "$*" >> "$REPLAY_ACTIONS"
  fi
  printf '%s' "${DATE_TS:?fixture must pin DATE_TS}"
}

# ── git seam ──
# Record the call. The push belt only calls git inside the PUSH_FAILED=1 branch
# (git add, git commit, git push).
git() {
  printf 'CALL git %s\n' "$*" >> "$REPLAY_ACTIONS"
}

# Ensure the marker directory exists so `date > "$MARKER"` doesn't fail.
mkdir -p docs/agents/retros