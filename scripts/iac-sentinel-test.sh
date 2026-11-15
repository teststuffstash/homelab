#!/usr/bin/env bash
# iac-sentinel-test — drives the REAL scripts/iac-sentinel.sh tick (the open-PR loop) through PATH
# stubs for its external commands: `gh` serves a scripted world (PR list, the head's combined
# status, a tiny tarball), `curl` records every status POST and answers with a scripted HTTP code,
# `gitleaks` exits clean (0) or leak (9). Run by `devbox run sentinel-smoke`.
# Pins the post-on-change rule (GitHub keeps ≤1000 statuses per sha+context; a re-post of an
# unchanged verdict every tick filled sleep-iac#80's head): no prior status → POST; the status this
# sentinel posted last tick, unchanged → no POST; a changed verdict → POST; an unreadable status →
# POST (fail toward judging); a head at the cap → logged as such, not a POST failure, run exits 0;
# and exactly ONE status read per head per tick.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/src"
SHA=0123456789abcdef0123456789abcdef01234567

cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
jqx=""; args=()
while [ $# -gt 0 ]; do case "$1" in --jq) jqx="$2"; shift 2 ;; *) args+=("$1"); shift ;; esac; done
printf '%s\n' "${args[*]}" >>"$WORLD/gh.log"
f=""
case "${args[0]:-} ${args[1]:-}" in
  "pr list") f="$WORLD/pr-list.json" ;;
  "api "*) p="${args[1]%%\?*}"
    case "$p" in
      */tarball/*) cat "$WORLD/tree.tgz"; exit 0 ;;
      */commits/*/status) f="$WORLD/status.json" ;;
      */commits/*) f="$WORLD/commit.json" ;;
    esac ;;
esac
[ -n "$f" ] && [ -f "$f" ] || exit 1      # absent world file = the probe fails (gh's non-zero exit)
if [ -n "$jqx" ]; then jq -r "$jqx" "$f"; else cat "$f"; fi
STUB
cat >"$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
out=""; data=""; url=""
while [ $# -gt 0 ]; do case "$1" in
  -o) out="$2"; shift 2 ;; -w|-H|--max-time) shift 2 ;; -d|--data-binary) data="$2"; shift 2 ;;
  -*) shift ;; *) url="$1"; shift ;; esac; done
printf '%s %s\n' "$url" "$data" >>"$WORLD/curl.log"
[ -n "$out" ] && printf '%s' "${POST_BODY:-{\}}" >"$out"
printf '%s' "${POST_CODE:-201}"
STUB
printf '#!/usr/bin/env bash\nexit "${GITLEAKS_RC:-0}"\n' >"$T/bin/gitleaks"
printf '#!/usr/bin/env bash\necho "stub: kyverno must not run (the test tree has no k8s docs)" >&2; exit 64\n' >"$T/bin/kyverno"
chmod +x "$T/bin/"*
echo hello >"$T/src/README"
tar -C "$T" -czf "$T/tree.tgz" src

bad=0
# run <case> — one tick over a one-PR world; leaves $WORLD/{curl.log,gh.log,out}
run() {
  export WORLD="$T/w-$1"; mkdir -p "$WORLD"; : >"$WORLD/curl.log"; : >"$WORLD/gh.log"
  cp "$T/tree.tgz" "$WORLD/"
  printf '[{"number":7,"headRefOid":"%s","author":{"login":"someone"}}]\n' "$SHA" >"$WORLD/pr-list.json"
  echo '{"commit":{"committer":{"date":"2026-01-01T00:00:00Z"}}}' >"$WORLD/commit.json"
  [ -n "${STATUS_JSON:-}" ] && printf '%s\n' "$STATUS_JSON" >"$WORLD/status.json"
  PATH="$T/bin:$PATH" ORG=testorg SENTINEL_REPOS=testrepo SENTINEL_STATUS_TOKEN=dummy \
    SENTINEL_WAKE=cron PUSHGATEWAY="" bash "$HERE/iac-sentinel.sh" >"$WORLD/out" 2>&1
  RC=$?
}
posts() { grep -c '/statuses/' "$WORLD/curl.log"; }
check() {  # <name> <condition-cmd...>
  local name="$1"; shift
  if "$@"; then echo "ok   $name"; else echo "FAIL $name"; sed 's/^/    /' "$WORLD/out"; bad=$((bad + 1)); fi
}
# the status a world serves: GitHub's combined-status shape, built from a recorded POST body
status_from_post() {  # <curl.log line's JSON body>
  jq -c '{state: .state, statuses: [{context: .context, state: .state, description: .description}]}' <<<"$1"
}

# 1. no prior status → POST (and the same single read still feeds the cron-serviced accounting)
STATUS_JSON='{"state":"pending","statuses":[{"context":"other-ctx","state":"success","description":"x"}]}' run first
check "no prior iac-sentinel status → one POST" [ "$(posts)" = 1 ]
check "no prior status → state success (clean tree)" grep -q '"state":"success"' "$WORLD/curl.log"
check "no prior status on an old head → CRON-SERVICED still logged" grep -q 'CRON-SERVICED' "$WORLD/out"
check "exactly one status read for the head" [ "$(grep -c '/commits/.*/status' "$WORLD/gh.log")" = 1 ]
PREV_POST="$(sed -n 's|^[^ ]*/statuses/[^ ]* ||p' "$WORLD/curl.log")"

# 2. the status the sentinel itself posted last tick, same tree → NO POST
STATUS_JSON="$(status_from_post "$PREV_POST")" run unchanged
check "unchanged verdict → no POST" [ "$(posts)" = 0 ]
check "unchanged verdict → said in the log" grep -q 'status unchanged (success)' "$WORLD/out"
check "exactly one status read for the head" [ "$(grep -c '/commits/.*/status' "$WORLD/gh.log")" = 1 ]

# 3. same prior status, the tree now leaks → the verdict changes → POST failure
STATUS_JSON="$(status_from_post "$PREV_POST")" GITLEAKS_RC=9 run changed
check "changed verdict → one POST" [ "$(posts)" = 1 ]
check "changed verdict → state failure" grep -q '"state":"failure"' "$WORLD/curl.log"
LEAK_POST="$(sed -n 's|^[^ ]*/statuses/[^ ]* ||p' "$WORLD/curl.log")"

# 4. same state, different description (a stale wording) → POST
STATUS_JSON="$(jq -c '.statuses[0].description = "older wording"' <<<"$(status_from_post "$PREV_POST")")" run desc
check "same state, changed description → one POST" [ "$(posts)" = 1 ]

# 5. the status read fails → POST anyway (an unreadable head is judged, never skipped)
STATUS_JSON="" run probe-fail
check "status read failed → one POST" [ "$(posts)" = 1 ]

# 6. a head at GitHub's cap: the changed verdict is refused with 422 → logged as the cap, not a failure
STATUS_JSON="$(status_from_post "$PREV_POST")" GITLEAKS_RC=9 POST_CODE=422 \
  POST_BODY='{"message":"Validation Failed","errors":[{"resource":"Status","code":"custom","message":"This SHA and context has reached the maximum number of statuses."}]}' run capped
check "capped head → POST attempted once" [ "$(posts)" = 1 ]
check "capped head → STATUS CAP REACHED logged" grep -q 'STATUS CAP REACHED' "$WORLD/out"
check "capped head → not a STATUS POST FAILED" bash -c '! grep -q "STATUS POST FAILED" "$1"' _ "$WORLD/out"
check "capped head → the run exits 0" [ "$RC" = 0 ]

# 7. a plain server error still reads as a POST failure (the cap branch is not a catch-all)
STATUS_JSON="$(status_from_post "$LEAK_POST")" POST_CODE=500 run server-error
check "server error → STATUS POST FAILED (HTTP 500)" grep -q 'STATUS POST FAILED (success, HTTP 500)' "$WORLD/out"

[ "$bad" -eq 0 ] || { echo "iac-sentinel-test: $bad check(s) failed"; exit 1; }
echo "iac-sentinel-test: OK"
