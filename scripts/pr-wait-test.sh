#!/usr/bin/env bash
# pr-wait-test — drives the REAL scripts/pr-wait.sh through its one seam (PR_WAIT_GH = a stub that
# serves a scripted SEQUENCE of `gh pr view` answers per PR, one line per poll, the last repeating).
# `devbox run pr-wait-test`. Pins the 2026-10-04 additions: a CONFLICTING head exits 6 (only on two
# consecutive polls — UNKNOWN while GitHub recomputes must not trip it), and several PRs in ONE call
# exit on the FIRST actionable outcome of any of them (the chained-waits blind spot, #2206/#2207).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PR_WAIT_GH="$T/gh" WORLD="$T/world"
cat >"$PR_WAIT_GH" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr merge") exit 0 ;;
  "pr view")
    f="$WORLD/view-$3"; n="$WORLD/.n-$3"; i=$(( $(cat "$n" 2>/dev/null || echo 0) + 1 )); echo "$i" >"$n"
    total=$(grep -c . "$f"); [ "$i" -gt "$total" ] && i=$total
    sed -n "${i}p" "$f"; exit 0 ;;
  "run list")
    head="$(printf '%s\n' "$@" | grep -A1 -x -- --commit | tail -1)"
    [ -f "$WORLD/red-$head" ] && cat "$WORLD/red-$head"; exit 0 ;;
  "api "*)
    case "$2" in */commits/*/status) h="${2#*/commits/}"; h="${h%/status}"; f="$WORLD/status-$h"; [ -f "$f" ] && jq -r "$4" <"$f"; exit 0 ;; esac
    exit 0 ;;
esac
echo "stub: unexpected $*" >&2; exit 64
STUB
chmod +x "$PR_WAIT_GH"
v() { printf '{"state":"%s","reviewDecision":"%s","headRefOid":"%s","mergeable":"%s"}\n' "$@"; }
pass=0; fail=0
case_() {  # <name> <want-rc> <want-grep> <pr-args…> — the world is set up by the caller first
  local name="$1" want="$2" grep_="$3" out rc; shift 3
  out="$(bash "$HERE/pr-wait.sh" "$@" --interval 0 --timeout 30 --no-arm 2>&1)"; rc=$?
  if [ "$rc" = "$want" ] && printf '%s' "$out" | grep -qF -- "$grep_"; then pass=$((pass+1)); echo "PASS $name (rc $rc)"
  else fail=$((fail+1)); echo "FAIL $name — want rc $want + '$grep_', got rc $rc:"; printf '%s\n' "$out" | sed 's/^/     /'; fi
  rm -rf "$WORLD"; mkdir -p "$WORLD"
}
mkdir -p "$WORLD"
# single PR, merges after two waiting polls — the original contract
{ v OPEN REVIEW_REQUIRED a1 MERGEABLE; v OPEN APPROVED a1 MERGEABLE; v MERGED APPROVED a1 MERGEABLE; } >"$WORLD/view-1"
case_ single-merges 0 "pr-wait: MERGED" 1
# a conflict seen on TWO consecutive polls exits 6
{ v OPEN REVIEW_REQUIRED b1 MERGEABLE; v OPEN REVIEW_REQUIRED b1 CONFLICTING; v OPEN REVIEW_REQUIRED b1 CONFLICTING; } >"$WORLD/view-2"
case_ conflict-exits-6 6 "#2 MERGE CONFLICT" 2
# CONFLICTING once, then UNKNOWN (GitHub recomputing), then MERGED — never a conflict exit
{ v OPEN REVIEW_REQUIRED c1 CONFLICTING; v OPEN REVIEW_REQUIRED c1 UNKNOWN; v MERGED APPROVED c1 MERGEABLE; } >"$WORLD/view-3"
case_ transient-conflict-ignored 0 "pr-wait: MERGED" 3
# two PRs: #4 keeps waiting, #5 goes CI-red — ONE call exits 4 on #5 (the chained-waits blind spot)
{ v OPEN REVIEW_REQUIRED d1 MERGEABLE; } >"$WORLD/view-4"
{ v OPEN REVIEW_REQUIRED e1 MERGEABLE; } >"$WORLD/view-5"
echo '{"databaseId":42,"name":"ci"}' >"$WORLD/red-e1"
case_ multi-first-actionable 4 "#5 CI RED at head" 4 5
# two PRs: #6 merges first and drops out, #7 merges later — exit 0 only when both have
{ v MERGED APPROVED f1 MERGEABLE; } >"$WORLD/view-6"
{ v OPEN APPROVED g1 MERGEABLE; v OPEN APPROVED g1 MERGEABLE; v MERGED APPROVED g1 MERGEABLE; } >"$WORLD/view-7"
case_ multi-all-merged 0 "pr-wait: MERGED" 6 7
# two PRs: one merged, the other conflicting — the conflict still surfaces
{ v MERGED APPROVED h1 MERGEABLE; } >"$WORLD/view-8"
{ v OPEN REVIEW_REQUIRED i1 CONFLICTING; } >"$WORLD/view-9"
case_ multi-merged-plus-conflict 6 "#9 MERGE CONFLICT" 8 9
# a red COMMIT STATUS (the box's management-sentinel posts one, not an Actions run) exits 4
{ v OPEN APPROVED k1 MERGEABLE; } >"$WORLD/view-11"
echo '{"statuses":[{"context":"ci","state":"success","description":"ok"},{"context":"management-sentinel","state":"failure","description":"plan errored: main"}]}' >"$WORLD/status-k1"
case_ status-red-exits-4 4 "#11 STATUS RED at head — management-sentinel: plan errored: main" 11
# a timeout names the PRs still open
{ v OPEN REVIEW_REQUIRED j1 MERGEABLE; } >"$WORLD/view-10"
out="$(bash "$HERE/pr-wait.sh" 10 --interval 1 --timeout 1 --no-arm 2>&1)"; rc=$?
if [ "$rc" = 5 ] && printf '%s' "$out" | grep -qF "on #10"; then pass=$((pass+1)); echo "PASS timeout-names-open (rc 5)"
else fail=$((fail+1)); echo "FAIL timeout-names-open — rc $rc:"; printf '%s\n' "$out" | sed 's/^/     /'; fi
echo "pr-wait-test: $pass passed, $fail failed"
[ "$fail" = 0 ]
