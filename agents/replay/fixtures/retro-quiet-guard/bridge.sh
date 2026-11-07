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

# DECLARATION (`expr-fires` ONLY, gated by `env: DECLARE_SCHEDULE=1`): the feedback-triage series'
# weekly fire is Argo's `suspend` field on its CronWorkflow — no shell reads it, so the assertion is
# the declaration read out of the shipped manifest (README §When the clause lives inside a
# manifest). Born suspended; unsuspended once its hand-fired run landed clean (homelab#3140).
if [ "${DECLARE_SCHEDULE:-0}" = "1" ]; then
  awk '/^  name: retro-feedback-triage$/ { c = 1; next }
       c && /^  suspend: / { printf "cron retro-feedback-triage suspend=%s\n", $2; exit }' \
    "$REPLAY_ROOT/agents/coordinator/retro-argo.yaml"
fi

STACK="${STACK:?fixture must pin STACK}"
WORK="$(mktemp -d)"
# The series knobs the manifest sets just above the block (homelab#3140): SERIES defaults to the
# stack (every pre-series row reads exactly as before); GUARD_EXPR empty = the ledger guard, set =
# the PromQL guard (the `expr-*` rows).
SERIES="${SERIES:-$STACK}"
GUARD_EXPR="${GUARD_EXPR:-}"

# python3 — TWO callees behind one name (homelab#3140). `retro_pipeline.py prepare` is the seam:
# record the call, exit PREP_RC. `retro_guard_expr.py` is the REAL verdict parser run on the
# shadowed curl's body below (extraction-never-transcription: the parser is the shipped file, its
# four verdict shapes are the `expr-*` rows), recorded by name.
python3() {
  local a="$*"
  printf 'CALL python3 %s\n' "${a//$WORK/\$WORK}" >> "$REPLAY_ACTIONS"
  case "$1" in
    agents/retro_guard_expr.py) command python3 "$REPLAY_ROOT/agents/retro_guard_expr.py";;
    *) return "${PREP_RC:?row must pin PREP_RC}";;
  esac
}

# curl — two shapes. The guard QUERY (`--get …/api/v1/query`, homelab#3140) answers with a canned
# Prometheus body built from PROM_VALUE: a number = one sample with that value; `absent` = an
# empty result; `error` = a non-success status; `down` = curl itself fails (-f on a dead server:
# no body, exit 22). Every other call is the pushgateway PUSH (the quiet-week belt): record it,
# consume stdin, CURL_RC_1 on the first push, CURL_RC_2 after (file counter: each pipe stage is
# its own subshell).
__curl_count_file="$REPLAY_ACTIONS.curl_count"
curl() {
  case "$*" in
    *api/v1/query*)
      printf 'CALL curl %s\n' "$*" >> "$REPLAY_ACTIONS"
      case "${PROM_VALUE:?expr row must pin PROM_VALUE}" in
        down)   return 22;;
        error)  printf '{"status":"error","errorType":"bad_data","error":"parse error"}';;
        absent) printf '{"status":"success","data":{"resultType":"vector","result":[]}}';;
        *)      printf '{"status":"success","data":{"resultType":"vector","result":[{"metric":{},"value":[1761523200,"%s"]}]}}' "$PROM_VALUE";;
      esac
      return 0;;
  esac
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
